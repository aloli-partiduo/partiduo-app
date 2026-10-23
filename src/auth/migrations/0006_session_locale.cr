# SPDX-License-Identifier: AGPL-3.0-or-later

# Langue d'une session ouverte par connect (D-UI-082) : celle du compte
# connect (claim `locale`), reprise à chaque connexion ; chaîne vide pour un
# compte connect sans langue (le navigateur décide) ; nulle pour toute autre
# session (langue de l'utilisateur du dossier, comme avant).
class Migration::Auth::V0006 < Marten::Migration
  depends_on :auth, "0005_connect"

  def plan
    add_column :auth_session, :locale, :string, max_size: 8, null: true
  end
end
