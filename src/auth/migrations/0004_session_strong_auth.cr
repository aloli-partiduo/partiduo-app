# SPDX-License-Identifier: AGPL-3.0-or-later

# Heure de la dernière authentification forte d'une session (A-SEPA-3) :
# second facteur (TOTP), passkey ou identité fédérée au niveau qu'exige
# l'utilisateur ; nulle pour les sessions ouvertes avant cette migration,
# qui devront se ré-authentifier pour approuver.
class Migration::Auth::V0004 < Marten::Migration
  depends_on :auth, "0003_user_interface"

  def plan
    add_column :auth_session, :strong_auth_at, :date_time, null: true
  end
end
