# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Approbation des opérations sensibles (A-SEPA-3, DECISIONS D-AMD-027 à
# D-AMD-029) : réglage du dossier (une ou deux personnes), authentification
# forte récente, une décision et une exécution par demande, piste d'audit.
# Specs d'attaque : même personne, authentification trop ancienne ou
# absente, approbation rejouée, exécution rejouée ou détournée.

private alias Approvals = Partiduo::Api::Approvals

# Extension d'essai, déclarant sa permission d'approbation, active le temps
# du bloc.
private def with_extension(& : String, String ->) : Nil
  code = "APR#{Random::Secure.hex(3).upcase}"
  permission = "#{code.downcase}.batch.approve"
  Partiduo::Modules.register do
    code code
    permission permission
  end
  begin
    with_active_modules(code.downcase) { yield code, permission }
  ensure
    Partiduo::Modules.manifests.delete(code)
  end
end

private def person(id : Int64, permission : String, strong : Time? = Time.utc) : Partiduo::Api::Actor
  Partiduo::Api::Actor.user(id, [permission], level: 3, strong_auth_at: strong)
end

private def submit(code : String, permission : String, by : Partiduo::Api::Actor, subject = "batch:1",
                   digest = "d1") : Approvals::ApprovalView
  Approvals.submit(by, Approvals::SubmitInput.new(module_code: code, kind: "batch", subject: subject,
    summary: "Virements du 15 octobre", digest: digest, permission: permission, amount: BigDecimal.new("1250.40"),
    currency_code: "eur", details: {"sepa.fields.count" => "3"})).value!
end

private def dual! : Nil
  settings = Partiduo::Api::Core.settings(Partiduo::Api::Actor.system)
  Partiduo::Api::Core.update_settings(actor_with("core.settings.manage"), settings.to_input.copy_with(approval_mode: "dual")).value!
end

private def actions(id : Int64) : Array(String)
  Approvals.events(Partiduo::Api::Actor.system, id).map { |event| "#{event.action}#{event.detail.starts_with?("core.") ? ":" + event.detail.split('.').last : ""}" }
end

describe "Approbations (A-SEPA-3)" do
  it "règle le dossier : une personne par défaut, deux sur demande, délai de 1 à 60 minutes, changement tracé" do
    provision_instance
    Approvals.policy(actor_with).mode.should eq("single")
    Approvals.policy(actor_with).reauth_minutes.should eq(5)
    admin = actor_with("core.settings.manage")
    current = Partiduo::Api::Core.settings(admin).to_input
    Partiduo::Api::Core.update_settings(admin, current.copy_with(approval_mode: "triple", approval_reauth_minutes: 61))
      .error_keys.should eq(["core.errors.settings.approval_mode.invalid", "core.errors.settings.approval_reauth_minutes.out_of_range"])
    view = Partiduo::Api::Core.update_settings(admin, current.copy_with(approval_mode: "dual", approval_reauth_minutes: 10)).value!
    view.dual_approval?.should be_true
    Approvals.policy(actor_with).dual?.should be_true
    # Une saisie qui ignore ces champs ne les change pas.
    Partiduo::Api::Core.update_settings(admin, settings_input(city: "Rezé")).value!.approval_reauth_minutes.should eq(10)
    Approvals.log(admin).map(&.action).should eq(["policy.changed"])
    Approvals.log(admin).first.detail.should eq("single/5 → dual/10")
  end

  it "laisse à une personne approuver sa demande après une authentification forte récente (repli à une personne)" do
    provision_instance
    with_extension do |code, permission|
      alone = person(1_i64, permission)
      request = submit(code, permission, alone)
      request.pending?.should be_true
      request.mode.should eq("single")
      request.amount.should eq(BigDecimal.new("1250.40"))
      request.currency_code.should eq("EUR")
      request.details.should eq({"sepa.fields.count" => "3"})
      Approvals.decision(alone, request.id).can_approve.should be_true
      approved = Approvals.approve(alone, request.id, "vu").value!
      approved.approved?.should be_true
      approved.decided_by_id.should eq(1)
      approved.decision_mode.should eq("single")
      approved.comment.should eq("vu")
      actions(request.id).should eq(["submitted", "approved"])
    end
  end

  describe "attaques" do
    it "refuse la même personne en validation à deux, même authentifiée fortement, et la base aussi" do
      provision_instance
      dual!
      with_extension do |code, permission|
        preparer = person(1_i64, permission)
        request = submit(code, permission, preparer)
        refused = Approvals.approve(preparer, request.id)
        refused.error_keys.should eq(["core.errors.approval.same_person"])
        ReferentialSpec.expect_translated(refused)
        Approvals.decision(preparer, request.id).reason.should eq("core.errors.approval.same_person")
        Approvals.approval(preparer, request.id).pending?.should be_true

        # Contourner le contrat : la base refuse l'approbation par la même personne.
        expect_raises(Exception, /core_approval_dual_check/) do
          EntrySpec.sql("UPDATE core_approval SET status = 'approved', decided_by_id = requested_by_id, " \
                        "decided_at = now(), decision_mode = 'dual' WHERE id = $1", request.id)
        end

        other = Approvals.approve(person(2_i64, permission), request.id).value!
        other.decided_by_id.should eq(2)
        other.decision_mode.should eq("dual")
        actions(request.id).should eq(["submitted", "refused:same_person", "approved"])
      end
    end

    it "lit le mode à la décision : une demande soumise à une personne passe à deux" do
      provision_instance
      with_extension do |code, permission|
        preparer = person(1_i64, permission)
        request = submit(code, permission, preparer)
        dual!
        Approvals.approve(preparer, request.id).error_keys.should eq(["core.errors.approval.same_person"])
      end
    end

    it "exige une authentification forte, et récente" do
      provision_instance
      with_extension do |code, permission|
        request = submit(code, permission, person(1_i64, permission))
        never = person(2_i64, permission, strong: nil)
        stale = person(2_i64, permission, strong: Time.utc - 6.minutes)
        future = person(2_i64, permission, strong: Time.utc + 1.hour)
        {never, stale, future}.each do |actor|
          result = Approvals.approve(actor, request.id)
          result.error_keys.should eq(["core.errors.approval.reauthentication_required"])
          result.errors.first.params["minutes"].should eq("5")
        end
        decision = Approvals.decision(stale, request.id)
        decision.can_approve.should be_false
        decision.reauthentication_required.should be_true
        Approvals.check_approve(stale, request.id).error_keys.should eq(["core.errors.approval.reauthentication_required"])

        settings = Partiduo::Api::Core.settings(Partiduo::Api::Actor.system)
        Partiduo::Api::Core.update_settings(actor_with("core.settings.manage"),
          settings.to_input.copy_with(approval_reauth_minutes: 10)).value!
        Approvals.approve(stale, request.id).value!.approved?.should be_true
        actions(request.id).count(&.==("refused:reauthentication_required")).should eq(3)
      end
    end

    it "refuse une approbation rejouée, un rejet après coup, une demande retirée" do
      provision_instance
      with_extension do |code, permission|
        approver = person(2_i64, permission)
        request = submit(code, permission, person(1_i64, permission))
        Approvals.approve(approver, request.id).success?.should be_true
        Approvals.approve(approver, request.id).error_keys.should eq(["core.errors.approval.not_pending"])
        Approvals.reject(approver, request.id).error_keys.should eq(["core.errors.approval.not_pending"])
        Approvals.cancel(person(1_i64, permission), request.id).error_keys.should eq(["core.errors.approval.not_pending"])

        withdrawn = submit(code, permission, person(1_i64, permission), subject: "batch:2")
        Approvals.cancel(person(1_i64, permission), withdrawn.id).value!.status.should eq("cancelled")
        Approvals.approve(approver, withdrawn.id).error_keys.should eq(["core.errors.approval.not_pending"])
        expect_raises(Partiduo::Api::Forbidden) { Approvals.cancel(approver, request.id) }
      end
    end

    it "n'exécute une approbation qu'une fois, pour l'objet et le contenu approuvés" do
      provision_instance
      with_extension do |code, permission|
        request = submit(code, permission, person(1_i64, permission), digest: "sha-du-lot")
        executor = actor_with
        expected = Approvals::ConsumeInput.new(code, "batch", "batch:1", "sha-du-lot")
        Approvals.consume(executor, request.id, expected).error_keys.should eq(["core.errors.approval.not_approved"])
        Approvals.approve(person(2_i64, permission), request.id).value!
        Approvals.consume(executor, request.id, expected.copy_with(subject: "batch:2"))
          .error_keys.should eq(["core.errors.approval.subject_mismatch"])
        Approvals.consume(executor, request.id, expected.copy_with(digest: "sha-modifie"))
          .error_keys.should eq(["core.errors.approval.digest_mismatch"])
        Approvals.consume(executor, request.id, expected).value!.consumed?.should be_true
        Approvals.consume(executor, request.id, expected).error_keys.should eq(["core.errors.approval.already_consumed"])
        actions(request.id).should eq(["submitted", "refused:not_approved", "approved", "refused:subject_mismatch",
                                       "refused:digest_mismatch", "consumed", "refused:already_consumed"])
        # La base refuse une exécution sans approbation.
        other = submit(code, permission, person(1_i64, permission), subject: "batch:3")
        expect_raises(Exception, /core_approval_consumed_check/) do
          EntrySpec.sql("UPDATE core_approval SET consumed_at = now() WHERE id = $1", other.id)
        end
      end
    end

    it "refuse sans la permission, à l'acteur système, à un anonyme" do
      provision_instance
      with_extension do |code, permission|
        request = submit(code, permission, person(1_i64, permission))
        stranger = Partiduo::Api::Actor.user(3_i64, [] of String, strong_auth_at: Time.utc)
        expect_raises(Partiduo::Api::Forbidden) { Approvals.approve(stranger, request.id) }
        expect_raises(Partiduo::Api::Forbidden) { Approvals.approve(Partiduo::Api::Actor.anonymous, request.id) }
        Approvals.approve(Partiduo::Api::Actor.system, request.id).error_keys.should eq(["core.errors.approval.person_required"])
        expect_raises(Partiduo::Api::NotFound) { Approvals.approval(Partiduo::Api::Actor.user(3_i64, [] of String), request.id) }
        Approvals.submit(Partiduo::Api::Actor.system, Approvals::SubmitInput.new(module_code: code, kind: "batch",
          subject: "batch:9", summary: "x", digest: "d", permission: permission))
          .error_keys.should eq(["core.errors.approval.person_required"])
      end
    end
  end

  it "ne garde qu'une demande en attente par objet, et refuse une demande mal formée" do
    provision_instance
    with_extension do |code, permission|
      submitter = person(1_i64, permission)
      submit(code, permission, submitter)
      Approvals.submit(submitter, Approvals::SubmitInput.new(module_code: code, kind: "batch", subject: "batch:1",
        summary: "Encore", digest: "d2", permission: permission)).error_keys.should eq(["core.errors.approval.pending_exists"])
      malformed = Approvals.submit(submitter, Approvals::SubmitInput.new(module_code: code, kind: "Lot !", subject: " ",
        summary: "", digest: "", permission: permission))
      malformed.error_keys.should eq(["core.errors.approval.kind.invalid", "core.errors.approval.subject.blank",
                                      "core.errors.approval.summary.blank", "core.errors.approval.digest.blank"])
      ReferentialSpec.expect_translated(malformed)
      expect_raises(ArgumentError, /permission non déclarée/) do
        Approvals.submit(submitter, Approvals::SubmitInput.new(module_code: code, kind: "batch", subject: "b",
          summary: "s", digest: "d", permission: "inconnue.batch.approve"))
      end
      expect_raises(Partiduo::Api::ModuleDisabled) do
        Approvals.submit(submitter, Approvals::SubmitInput.new(module_code: "INCONNU", kind: "batch", subject: "b",
          summary: "s", digest: "d", permission: permission))
      end
    end
  end

  it "exécute le gestionnaire de l'extension dans la transaction de l'approbation" do
    provision_instance
    with_extension do |code, permission|
      calls = [] of Int64
      Approvals.register_handler(code, "batch") do |actor, approval|
        calls << approval.id
        next Partiduo::Api::Result(Nil).failure(Partiduo::Api::FieldError.base("core.errors.approval.digest_mismatch")) if approval.subject == "batch:refus"
        consumed = Approvals.consume(actor, approval.id, Approvals::ConsumeInput.new(code, "batch", approval.subject, approval.digest))
        consumed.failure? ? Partiduo::Api::Result(Nil).failure(consumed.errors) : Partiduo::Api::Result(Nil).success(nil)
      end
      begin
        approver = person(2_i64, permission)
        good = submit(code, permission, person(1_i64, permission))
        Approvals.approve(approver, good.id).value!.consumed?.should be_true
        bad = submit(code, permission, person(1_i64, permission), subject: "batch:refus")
        Approvals.approve(approver, bad.id).error_keys.should eq(["core.errors.approval.digest_mismatch"])
        Approvals.approval(approver, bad.id).pending?.should be_true
        calls.should eq([good.id, bad.id])
      ensure
        Approvals.unregister_handler(code, "batch")
      end
    end
  end

  it "liste les demandes à décider, celles soumises par l'acteur, et les compte" do
    provision_instance
    with_extension do |code, permission|
      submit(code, permission, person(1_i64, permission))
      submit(code, permission, person(1_i64, permission), subject: "batch:2")
      Approvals.pending(person(2_i64, permission)).size.should eq(2)
      Approvals.pending_count(person(2_i64, permission)).should eq(2)
      Approvals.pending_count(person(2_i64, permission, strong: nil)).should eq(2) # après ré-authentification
      Approvals.pending(Partiduo::Api::Actor.user(1_i64, [] of String)).size.should eq(2)
      Approvals.pending(Partiduo::Api::Actor.user(3_i64, [] of String)).should be_empty
      Approvals.latest(person(2_i64, permission), code, "batch", "batch:2").try(&.subject).should eq("batch:2")
    end
  end
end

describe "Authentification forte d'une session (A-SEPA-3)" do
  it "la note à la connexion par TOTP, pas par mot de passe seul ni par code de récupération, et à l'élévation" do
    AuthSpec.create_user
    password_token = AuthSpec.session_token
    AuthSpec.actor(password_token).strong_auth_at.should be_nil
    secret, codes = AuthSpec.enable_totp(AuthSpec.actor(password_token))

    pending = AuthSpec.login.value!.pending_token!
    recovery = Partiduo::Api::Auth.login_second_factor(Partiduo::Api::Actor.anonymous,
      Partiduo::Api::Auth::SecondFactorInput.new(pending_token: pending, code: codes.first, kind: "recovery_code")).value!
    AuthSpec.actor(recovery.session_token!).strong_auth_at.should be_nil

    pending = AuthSpec.login.value!.pending_token!
    strong = Partiduo::Api::Auth.login_second_factor(Partiduo::Api::Actor.anonymous,
      Partiduo::Api::Auth::SecondFactorInput.new(pending_token: pending, code: AuthSpec.totp_code(secret), kind: "totp")).value!
    actor = AuthSpec.actor(strong.session_token!)
    actor.strong_auth_at.should_not be_nil
    actor.strong_auth_within?(5.minutes).should be_true
    Partiduo::Api::Auth.session(strong.session_token!).try(&.strong_auth_at).should_not be_nil

    # Ré-authentification d'une session déjà forte : l'heure est renouvelée.
    Partiduo::Auth::Session.filter(id: actor.session_id).update(strong_auth_at: Time.utc - 1.hour)
    AuthSpec.actor(strong.session_token!).strong_auth_within?(5.minutes).should be_false
    Partiduo::Api::Auth.elevate_with_totp(actor, strong.session_token!, AuthSpec.totp_code(secret, Time.utc + 30.seconds)).value!
    AuthSpec.actor(strong.session_token!).strong_auth_within?(5.minutes).should be_true
  end

  it "ne la donne jamais à l'acteur système" do
    Partiduo::Api::Actor.system.strong_auth_within?(5.minutes).should be_false
  end
end
