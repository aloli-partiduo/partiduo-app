# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module Partiduo
  module Api
    # Contrat du socle — approbation des opérations sensibles (A-SEPA-3) :
    # une règle commune à toutes les extensions, sur le modèle de la
    # validation à deux de l'administration du parc (D-VAL2-001 à
    # D-VAL2-006). Référence : `doc/api/approvals.adoc`.
    #
    # * *Réglage du dossier* (`SettingsView#approval_mode`) : `single`, une
    #   personne peut approuver ce qu'elle a soumis ; `dual`, une autre
    #   personne doit l'approuver. Le mode est lu *à la décision*, pas figé
    #   à la soumission (D-VAL2-006).
    # * *Authentification forte récente* : approuver exige une
    #   authentification forte (TOTP, passkey, identité fédérée) datant de
    #   moins de `approval_reauth_minutes` (`Actor#strong_auth_at`), dans
    #   les deux modes — c'est la protection de repli à une personne
    #   (D-VAL2-004).
    # * *Une décision par demande* : approuver, rejeter ou annuler n'agit que
    #   sur une demande en attente (mise à jour conditionnelle, atomique) ;
    #   rejouer une approbation est refusé.
    # * *Une exécution par approbation* : l'extension « consomme »
    #   l'approbation en exécutant l'opération (`consume`), une seule fois,
    #   pour l'objet et le contenu (empreinte) approuvés.
    # * *Piste d'audit* (`events`, `log`) : soumission, décisions, refus,
    #   consommation, changement de règle ; en ajout seul.
    #
    # ```
    # # Extension : soumettre le lot préparé.
    # Approvals.submit(actor, Approvals::SubmitInput.new(module_code: "SEPA", kind: "batch",
    #   subject: "batch:#{batch.id}", summary: "Virements du 15 octobre", digest: sha256,
    #   permission: "sepa.batch.approve", amount: total, currency_code: "EUR"))
    #
    # # Exécuter ce qui a été approuvé (une fois), à l'approbation…
    # Approvals.register_handler("SEPA", "batch") do |actor, approval|
    #   Sepa::Api.execute_approved(actor, approval) # appelle Approvals.consume
    # end
    # ```
    module Approvals
      STATUSES = %w[pending approved rejected cancelled]
      KIND     = /\A[a-z][a-z0-9_.]{0,63}\z/

      # Demande soumise par une extension : pièce, nature (`batch`), objet
      # (`batch:42`, unique parmi les demandes en attente), résumé lisible,
      # empreinte du contenu soumis (SHA-256 en hexadécimal, par exemple),
      # permission exigée pour décider (déclarée par l'extension), montant
      # et devise facultatifs, détails affichés par l'écran d'approbation
      # (`clé i18n => valeur`).
      record SubmitInput,
        module_code : String,
        kind : String,
        subject : String,
        summary : String,
        digest : String,
        permission : String,
        amount : BigDecimal? = nil,
        currency_code : String = "",
        details : Hash(String, String) = {} of String => String

      # Ce que l'extension exécute, pour vérifier qu'il a bien été approuvé.
      record ConsumeInput, module_code : String, kind : String, subject : String, digest : String

      record ApprovalView,
        id : Int64,
        module_code : String,
        kind : String,
        subject : String,
        summary : String,
        amount : BigDecimal?,
        currency_code : String,
        digest : String,
        permission : String,
        details : Hash(String, String),
        mode : String,
        status : String,
        requested_by_id : Int64,
        requested_at : Time,
        decided_by_id : Int64?,
        decided_at : Time?,
        decision_mode : String,
        comment : String,
        consumed_at : Time?,
        requested_by_name : String = "",
        decided_by_name : String = "" do
        def pending? : Bool
          status == "pending"
        end

        def approved? : Bool
          status == "approved"
        end

        def consumed? : Bool
          !consumed_at.nil?
        end

        # Clé i18n de l'état (`core.approvals.statuses.pending`).
        def status_key : String
          "core.approvals.statuses.#{status}"
        end
      end

      # Entrée de la piste d'audit ; `action` : `submitted`, `approved`,
      # `rejected`, `cancelled`, `consumed`, `refused` (`detail` : clé du
      # refus), `policy.changed`.
      record EventView, id : Int64, approval_id : Int64?, action : String, actor_id : Int64?, detail : String,
        created_at : Time, actor_name : String = "" do
        def action_key : String
          "core.approvals.actions.#{action.tr(".", "_")}"
        end
      end

      # Règle du dossier.
      record PolicyView, mode : String, reauth_minutes : Int32 do
        def dual? : Bool
          mode == "dual"
        end
      end

      # Ce que l'acteur peut faire d'une demande, pour l'écran : décider
      # (approuver ou rejeter), ou pourquoi pas (`reason`, clé i18n) ;
      # `reauthentication_required` : il le pourrait après une
      # authentification forte.
      record DecisionView, can_approve : Bool, can_reject : Bool, can_cancel : Bool, reason : String?,
        reauthentication_required : Bool, reauth_minutes : Int32

      # Exécution d'une approbation par l'extension, dans la transaction de
      # l'approbation : un échec annule l'approbation (la demande reste en
      # attente) et ses erreurs sont rendues.
      alias Handler = Proc(Actor, ApprovalView, Result(Nil))

      @@handlers = {} of {String, String} => Handler

      # Déclare ce qu'une extension exécute quand une demande de nature
      # `kind` est approuvée (par l'écran commun d'approbation ou par
      # `approve`). Facultatif : sans gestionnaire, l'extension exécute plus
      # tard et consomme alors l'approbation.
      def self.register_handler(module_code : String, kind : String, &block : Actor, ApprovalView -> Result(Nil)) : Nil
        @@handlers[{module_code.upcase, kind}] = block
      end

      # Specs : retire un gestionnaire.
      def self.unregister_handler(module_code : String, kind : String) : Nil
        @@handlers.delete({module_code.upcase, kind})
      end

      # --- Requêtes ------------------------------------------------------------

      # Règle du dossier ; avant le provisionnement, `single` et 5 minutes.
      def self.policy(actor : Actor) : PolicyView
        Guard.authorize!(actor, nil)
        current_policy
      end

      # Une demande : visible de qui l'a soumise, de qui l'a décidée et de
      # qui peut la décider. `NotFound` sinon.
      def self.approval(actor : Actor, id : Int64) : ApprovalView
        Guard.authorize!(actor, nil)
        row = find(id)
        raise NotFound.new("approval", id) unless visible?(actor, row)
        view(row)
      end

      # Demandes en attente que l'acteur peut décider (il a la permission),
      # et celles qu'il a soumises ; de la plus ancienne à la plus récente.
      def self.pending(actor : Actor, module_code : String? = nil) : Array(ApprovalView)
        Guard.authorize!(actor, nil)
        rows = Partiduo::Core::Approval.filter(status: "pending")
        module_code.try { |code| rows = rows.filter(module_code: code.strip.upcase) }
        rows.order(:requested_at, :id).to_a.select { |row| visible?(actor, row) && Partiduo::Modules.active?(row.module_code!) }
          .map { |row| view(row) }
      end

      # Nombre de demandes en attente que l'acteur peut approuver (compteur
      # du menu et « À traiter »).
      def self.pending_count(actor : Actor) : Int64
        pending(actor).count do |view|
          decision = decision_for(actor, view)
          decision.can_approve || decision.reauthentication_required
        end.to_i64
      end

      # Dernière demande d'un objet, quelle que soit son état ; `nil` s'il
      # n'y en a pas ou si l'acteur ne la voit pas.
      def self.latest(actor : Actor, module_code : String, kind : String, subject : String) : ApprovalView?
        Guard.authorize!(actor, nil)
        row = Partiduo::Core::Approval.filter(module_code: module_code.strip.upcase, kind: kind, subject: subject)
          .order("-id").first
        row && visible?(actor, row) ? view(row) : nil
      end

      # Ce que l'acteur peut faire de la demande (écran d'approbation).
      def self.decision(actor : Actor, id : Int64) : DecisionView
        decision_for(actor, approval(actor, id))
      end

      # Piste d'audit d'une demande, dans l'ordre.
      def self.events(actor : Actor, id : Int64) : Array(EventView)
        approval(actor, id)
        Partiduo::Core::ApprovalEvent.filter(approval_id: id).order(:id).to_a.map { |row| event_view(row) }
      end

      # Piste d'audit du dossier (toutes demandes et changements de règle),
      # de la plus récente à la plus ancienne. Droit : `core.settings.manage`.
      def self.log(actor : Actor, limit : Int32 = 200, offset : Int32 = 0) : Array(EventView)
        Guard.authorize!(actor, "core.settings.manage")
        start = offset.clamp(0, nil)
        Partiduo::Core::ApprovalEvent.all.order("-id")[start...(start + limit.clamp(1, 1000))].to_a.map { |row| event_view(row) }
      end

      # --- Commandes -----------------------------------------------------------

      # Soumet une opération à approbation, au nom de la pièce
      # `module_code` (active), par une personne authentifiée.
      #
      # Refus (`core.errors.approval.*`) : `person_required` (acteur
      # système), `kind.invalid`, `subject.blank`, `subject.too_long`,
      # `summary.blank`, `digest.blank`, `pending_exists` (une demande attend
      # déjà pour cet objet). Une permission non déclarée lève
      # `ArgumentError` (faute de l'extension).
      def self.submit(actor : Actor, input : SubmitInput) : Result(ApprovalView)
        Guard.authorize!(actor, nil)
        code = input.module_code.strip.upcase
        Guard.require_module!(code)
        unless Partiduo::Modules.permission_declared?(input.permission)
          raise ArgumentError.new("permission non déclarée dans un manifeste : #{input.permission}")
        end
        errors = submit_errors(actor, input)
        return Result(ApprovalView).failure(errors) unless errors.empty?
        Transaction.run do
          subject = input.subject.strip
          if Partiduo::Core::Approval.filter(module_code: code, kind: input.kind, subject: subject, status: "pending").exists?
            next Result(ApprovalView).failure(error("subject", "pending_exists"))
          end
          row = Partiduo::Core::Approval.create!(
            module_code: code, kind: input.kind, subject: subject, summary: input.summary.strip[0, 255],
            amount: input.amount, currency_code: input.currency_code.strip.upcase, digest: input.digest.strip,
            permission: input.permission, details: JSON.parse(input.details.to_json), mode: current_policy.mode,
            status: "pending", requested_by_id: actor.user_id.as(Int64), requested_at: Time.utc,
          )
          Partiduo::Core::ApprovalLog.record(row.id!.to_i64, "submitted", actor.user_id, "mode #{row.mode}")
          Result(ApprovalView).success(view(row))
        end
      end

      # Contrôle d'une approbation, sans décider (écran) : mêmes refus
      # qu'`approve`, rien n'est écrit.
      def self.check_approve(actor : Actor, id : Int64) : Result(Nil)
        row = authorized_row(actor, id)
        refusal = approval_refusal(actor, row)
        refusal ? Result(Nil).failure(refusal) : Result(Nil).success(nil)
      end

      # Approuve une demande en attente. Exige la permission de la demande,
      # une personne, une authentification forte récente et, en validation
      # à deux, une autre personne que celle qui a soumis. Le gestionnaire
      # de l'extension (`register_handler`) s'exécute dans la même
      # transaction. Chaque refus est inscrit à la piste d'audit.
      #
      # Refus (`core.errors.approval.*`, champ `base`) : `person_required`,
      # `not_pending` (déjà décidée : une approbation rejouée),
      # `same_person`, `reauthentication_required` (`%{minutes}`) ; erreurs
      # du gestionnaire.
      def self.approve(actor : Actor, id : Int64, comment : String = "") : Result(ApprovalView)
        row = authorized_row(actor, id)
        if refusal = approval_refusal(actor, row)
          Partiduo::Core::ApprovalLog.record(id, "refused", actor.user_id, refusal.key)
          return Result(ApprovalView).failure(refusal)
        end
        policy = current_policy
        result = Transaction.run do
          updated = Partiduo::Core::Approval.filter(id: id, status: "pending").update(
            status: "approved", decided_by_id: actor.user_id, decided_at: Time.utc, decision_mode: policy.mode,
            strong_auth_at: actor.strong_auth_at, comment: comment.strip)
          next Result(ApprovalView).failure(error(FieldError::BASE, "not_pending")) if updated.zero?
          approved = view(find(id))
          if handler = @@handlers[{approved.module_code, approved.kind}]?
            outcome = handler.call(actor, approved)
            next Result(ApprovalView).failure(outcome.errors) if outcome.failure?
          end
          Partiduo::Core::ApprovalLog.record(id, "approved", actor.user_id, "mode #{policy.mode}")
          Result(ApprovalView).success(view(find(id)))
        end
        if result.failure?
          Partiduo::Core::ApprovalLog.record(id, "refused", actor.user_id, result.errors.map(&.key).join(", "))
        end
        result
      end

      # Rejette une demande en attente (permission de la demande ; pas
      # d'authentification forte : rejeter ne fait rien). `comment` : motif.
      def self.reject(actor : Actor, id : Int64, comment : String = "") : Result(ApprovalView)
        row = authorized_row(actor, id)
        decide(actor, row, "rejected", comment)
      end

      # Retire une demande en attente : la personne qui l'a soumise, ou
      # l'extension elle-même (acteur système, objet modifié ou supprimé).
      def self.cancel(actor : Actor, id : Int64, comment : String = "") : Result(ApprovalView)
        Guard.authorize!(actor, nil)
        row = find(id)
        Guard.require_module!(row.module_code!)
        raise Forbidden.new unless actor.system || actor.user_id == row.requested_by_id
        decide(actor, row, "cancelled", comment)
      end

      # Exécution de ce qui a été approuvé, par l'extension : l'approbation
      # doit porter sur cet objet (`module_code`, `kind`, `subject`) et ce
      # contenu (`digest`), et n'avoir pas déjà servi. Une seule exécution
      # par approbation, même concurrente.
      #
      # Refus (`core.errors.approval.*`, champ `base`) : `not_approved`,
      # `already_consumed`, `subject_mismatch`, `digest_mismatch`.
      def self.consume(actor : Actor, id : Int64, expected : ConsumeInput) : Result(ApprovalView)
        Guard.authorize!(actor, nil)
        row = find(id)
        Guard.require_module!(row.module_code!)
        refusal = if row.status != "approved"
                    error(FieldError::BASE, "not_approved")
                  elsif !row.consumed_at.nil?
                    error(FieldError::BASE, "already_consumed")
                  elsif {row.module_code, row.kind, row.subject} != {expected.module_code.strip.upcase, expected.kind, expected.subject.strip}
                    error(FieldError::BASE, "subject_mismatch")
                  elsif row.digest != expected.digest.strip
                    error(FieldError::BASE, "digest_mismatch")
                  end
        if refusal
          Partiduo::Core::ApprovalLog.record(id, "refused", actor.user_id, refusal.key)
          return Result(ApprovalView).failure(refusal)
        end
        Transaction.run do
          updated = Partiduo::Core::Approval.filter(id: id, status: "approved", consumed_at__isnull: true)
            .update(consumed_at: Time.utc, consumed_by_id: actor.user_id)
          next Result(ApprovalView).failure(error(FieldError::BASE, "already_consumed")) if updated.zero?
          Partiduo::Core::ApprovalLog.record(id, "consumed", actor.user_id)
          Result(ApprovalView).success(view(find(id)))
        end
      end

      # --- Interne -------------------------------------------------------------

      protected def self.current_policy : PolicyView
        settings = Partiduo::Core::SettingsRules.current
        PolicyView.new(
          settings.try(&.approval_mode.presence) || Partiduo::Core::SettingsRules::DEFAULT_APPROVAL_MODE,
          (settings.try(&.approval_reauth_minutes) || Partiduo::Core::SettingsRules::DEFAULT_APPROVAL_REAUTH_MINUTES).to_i32,
        )
      end

      # Demande dont l'acteur a la permission (pièce active) ; `NotFound` si
      # elle n'existe pas.
      private def self.authorized_row(actor : Actor, id : Int64) : Partiduo::Core::Approval
        row = find(id)
        Guard.authorize!(actor, row.permission!, module_code: row.module_code!)
        row
      end

      # Raison de refuser l'approbation à l'acteur, ou `nil`.
      private def self.approval_refusal(actor : Actor, row : Partiduo::Core::Approval) : FieldError?
        policy = current_policy
        return error(FieldError::BASE, "person_required") if actor.system || actor.user_id.nil?
        return error(FieldError::BASE, "not_pending") unless row.status == "pending"
        return error(FieldError::BASE, "same_person") if policy.dual? && actor.user_id == row.requested_by_id
        unless actor.strong_auth_within?(policy.reauth_minutes.minutes)
          return error(FieldError::BASE, "reauthentication_required", {"minutes" => policy.reauth_minutes.to_s})
        end
        nil
      end

      private def self.decision_for(actor : Actor, view : ApprovalView) : DecisionView
        policy = current_policy
        holder = Partiduo::Modules.active?(view.module_code) && actor.can?(view.permission) && actor.elevated
        row = find(view.id)
        refusal = holder ? approval_refusal(actor, row) : error(FieldError::BASE, "forbidden")
        reauth = refusal.try(&.key.ends_with?(".reauthentication_required")) || false
        DecisionView.new(
          can_approve: refusal.nil?, can_reject: holder && view.pending?,
          can_cancel: view.pending? && actor.user_id == view.requested_by_id,
          reason: refusal.try(&.key), reauthentication_required: reauth, reauth_minutes: policy.reauth_minutes,
        )
      end

      private def self.decide(actor : Actor, row : Partiduo::Core::Approval, status : String, comment : String) : Result(ApprovalView)
        id = row.id!.to_i64
        Transaction.run do
          updated = Partiduo::Core::Approval.filter(id: id, status: "pending").update(
            status: status, decided_by_id: actor.user_id, decided_at: Time.utc, comment: comment.strip)
          next Result(ApprovalView).failure(error(FieldError::BASE, "not_pending")) if updated.zero?
          Partiduo::Core::ApprovalLog.record(id, status, actor.user_id, comment.strip)
          Result(ApprovalView).success(view(find(id)))
        end
      end

      private def self.submit_errors(actor : Actor, input : SubmitInput) : Array(FieldError)
        errors = [] of FieldError
        errors << error(FieldError::BASE, "person_required") if actor.system || actor.user_id.nil?
        errors << error("kind", "kind.invalid", {"value" => input.kind}) unless input.kind.matches?(KIND)
        subject = input.subject.strip
        if subject.empty?
          errors << error("subject", "subject.blank")
        elsif subject.size > 128
          errors << error("subject", "subject.too_long", {"max" => "128"})
        end
        errors << error("summary", "summary.blank") if input.summary.strip.empty?
        digest = input.digest.strip
        errors << error("digest", "digest.blank") if digest.empty? || digest.size > 128
        errors
      end

      # Une personne voit une demande qu'elle a soumise, décidée, ou qu'elle
      # peut décider.
      private def self.visible?(actor : Actor, row : Partiduo::Core::Approval) : Bool
        return true if actor.system
        user = actor.user_id
        (user && (row.requested_by_id == user || row.decided_by_id == user)) || (actor.elevated && actor.can?(row.permission!))
      end

      private def self.find(id : Int64) : Partiduo::Core::Approval
        Partiduo::Core::Approval.filter(id: id).first || raise NotFound.new("approval", id)
      end

      private def self.view(row : Partiduo::Core::Approval) : ApprovalView
        details = row.details.try(&.as_h?).try(&.transform_values(&.to_s)) || {} of String => String
        ApprovalView.new(
          id: row.id!.to_i64, module_code: row.module_code!, kind: row.kind!, subject: row.subject!,
          summary: row.summary!, amount: row.amount, currency_code: row.currency_code.to_s, digest: row.digest!,
          permission: row.permission!, details: details, mode: row.mode!, status: row.status!,
          requested_by_id: row.requested_by_id!.to_i64, requested_at: row.requested_at!,
          decided_by_id: row.decided_by_id.try(&.to_i64), decided_at: row.decided_at,
          decision_mode: row.decision_mode.to_s, comment: row.comment.to_s, consumed_at: row.consumed_at,
          requested_by_name: person_name(row.requested_by_id.try(&.to_i64)),
          decided_by_name: person_name(row.decided_by_id.try(&.to_i64)),
        )
      end

      # Nom affiché d'une personne (écran d'approbation, piste d'audit) ;
      # vide si elle n'existe plus.
      private def self.person_name(id : Int64?) : String
        return "" if id.nil?
        Partiduo::Api::Auth.user(Actor.system, id).full_name
      rescue NotFound
        ""
      end

      private def self.event_view(row : Partiduo::Core::ApprovalEvent) : EventView
        EventView.new(id: row.id!.to_i64, approval_id: row.approval_id.try(&.as(Int).to_i64), action: row.action!,
          actor_id: row.actor_id.try(&.to_i64), detail: row.detail.to_s, created_at: row.created_at!,
          actor_name: person_name(row.actor_id.try(&.to_i64)))
      end

      private def self.error(field : String, key : String, params = {} of String => String) : FieldError
        FieldError.new(field, "core.errors.approval.#{key}", params)
      end
    end
  end
end
