# SPDX-License-Identifier: AGPL-3.0-or-later

# Identité commune (ADR-012) : la session d'un dossier garde l'identifiant
# de session de connect (`sid`), que reprend la déconnexion par canal
# arrière (D8) ; une invitation garde le lien de création du compte connect
# (D6), qui ne sert qu'avec le code transmis par un autre canal.
class Migration::Auth::V0005 < Marten::Migration
  depends_on :auth, "0004_session_strong_auth"

  def plan
    add_column :auth_session, :federated_sid, :string, max_size: 64, null: true
    add_column :auth_token, :signup_url, :string, max_size: 1000, default: ""
    execute("CREATE INDEX auth_session_federated_sid ON auth_session (federated_sid) WHERE federated_sid IS NOT NULL",
      "DROP INDEX auth_session_federated_sid")
  end
end
