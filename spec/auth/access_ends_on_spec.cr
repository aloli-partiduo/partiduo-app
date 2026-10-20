# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Fin d'accès jugée au jour du dossier, dans son fuseau (DECISIONS
# D-AMD-035), et non au jour UTC : autour de minuit à Paris (UTC+2 en
# octobre 2026, jusqu'au 25), l'accès qui finit le 19 vaut jusqu'à 23 h 59
# le 19, heure de Paris, soit 21 h 59 UTC.

private PARIS_MIDNIGHT = Time.utc(2026, 10, 19, 22, 0, 0) # le 20 à 0 h, heure de Paris
private LAST_DAY       = Time.utc(2026, 10, 19)

private def in_paris(&) : Nil
  Partiduo::Config.time_zone.name.should eq("Europe/Paris")
  yield
end

private def admin_actor : Partiduo::Api::Actor
  AuthSpec.create_user("patron@societe.example", first_name: "Paul", last_name: "Patron")
  AuthSpec.actor(AuthSpec.session_token("patron@societe.example"))
end

private def accountant_input(ends : Time?) : Partiduo::Api::Auth::UserInput
  Partiduo::Api::Auth::UserInput.new(email: "expert@cabinet.example", role: "accountant",
    first_name: "Claire", last_name: "Expert", access_ends_on: ends)
end

describe "Fin d'accès au jour du dossier (D-AMD-035)" do
  it "date un instant dans le fuseau du dossier, à minuit UTC" do
    in_paris do
      Partiduo::Config.today_at(PARIS_MIDNIGHT - 1.second).should eq(LAST_DAY)
      Partiduo::Config.today_at(PARIS_MIDNIGHT).should eq(LAST_DAY + 1.day)
      Partiduo::Config.travel_to(PARIS_MIDNIGHT + 30.minutes) { Partiduo::Config.today.should eq(LAST_DAY + 1.day) }
    end
  end

  it "garde l'accès jusqu'à 23 h 59 heure de Paris, le coupe à minuit heure de Paris" do
    in_paris do
      user = Partiduo::Auth::User.new(access_ends_on: LAST_DAY, is_active: true)
      user.access_expired?(PARIS_MIDNIGHT - 1.second).should be_false
      user.can_sign_in?(PARIS_MIDNIGHT - 1.second).should be_true
      # Encore le 19 en UTC, déjà le 20 à Paris : l'accès est échu.
      user.access_expired?(PARIS_MIDNIGHT).should be_true
      user.access_expired?(PARIS_MIDNIGHT + 1.hour + 59.minutes).should be_true
      user.can_sign_in?(PARIS_MIDNIGHT).should be_false
      # Le 19 à 0 h 30 heure de Paris, encore le 18 en UTC : l'accès vaut.
      user.access_expired?(LAST_DAY - 90.minutes).should be_false
    end
  end

  it "coupe la session d'un comptable dont l'accès finit, au jour de Paris" do
    in_paris do
      created = AuthSpec.create_user("expert@cabinet.example", role: "accountant", profile: "ADMIN",
        first_name: "Claire", last_name: "Expert")
      AuthSpec.user_model(created.user.id).tap(&.access_ends_on=(LAST_DAY)).save!
      AuthSpec.user_model(created.user.id).can_sign_in?(PARIS_MIDNIGHT - 1.minute).should be_true
      AuthSpec.user_model(created.user.id).can_sign_in?(PARIS_MIDNIGHT + 1.minute).should be_false
    end
  end

  it "refuse à la création une fin d'accès d'hier au jour de Paris, accepte celle du jour" do
    in_paris do
      Partiduo::Config.travel_to(PARIS_MIDNIGHT + 30.minutes) do
        Partiduo::Api::Auth.create_user(AuthSpec.system, accountant_input(LAST_DAY)).errors_for("access_ends_on")
          .map(&.key).should eq(["auth.errors.user.access_ends_on_past"])
      end
      Partiduo::Config.travel_to(PARIS_MIDNIGHT - 30.minutes) do
        Partiduo::Api::Auth.create_user(AuthSpec.system, accountant_input(LAST_DAY)).success?.should be_true
      end
    end
  end

  it "rouvre l'accès jusqu'au jour de Paris, pas au-delà" do
    in_paris do
      admin = admin_actor
      created = AuthSpec.create_user("expert@cabinet.example", role: "accountant", profile: "ADMIN",
        first_name: "Claire", last_name: "Expert")
      Partiduo::Api::Auth.revoke_access(admin, created.user.id).success?.should be_true
      Partiduo::Config.travel_to(PARIS_MIDNIGHT + 30.minutes) do
        Partiduo::Api::Auth.restore_access(admin, created.user.id, LAST_DAY).error_keys
          .should eq(["auth.errors.user.access_ends_on_past"])
        view = Partiduo::Api::Auth.restore_access(admin, created.user.id, LAST_DAY + 1.day).value!
        view.access_ends_on.should eq(LAST_DAY + 1.day)
      end
      Partiduo::Config.travel_to(PARIS_MIDNIGHT - 30.minutes) do
        Partiduo::Api::Auth.restore_access(admin, created.user.id, LAST_DAY).value!.access_ends_on.should eq(LAST_DAY)
      end
    end
  end
end
