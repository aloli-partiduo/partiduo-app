# SPDX-License-Identifier: AGPL-3.0-or-later

# Import de fiches depuis un fichier CSV (DECISIONS D-OUT-003) : la
# permission `cards.card.import` est accordée aux profils qui peuvent déjà
# créer et modifier les fiches une à une (`cards.card.write`), comme le
# profil ACCOUNTANT créé au provisionnement. Retour : la permission est
# retirée de tous les profils.
class Migration::Cards::V0005 < Marten::Migration
  depends_on :cards, "0004_supplier_person"
  depends_on :auth, "0002_auth_security"

  def plan
    execute(
      "INSERT INTO auth_profile_permission (profile_id, permission) " \
      "SELECT profile_id, 'cards.card.import' FROM auth_profile_permission WHERE permission = 'cards.card.write' " \
      "ON CONFLICT (profile_id, permission) DO NOTHING",
      "DELETE FROM auth_profile_permission WHERE permission = 'cards.card.import'"
    )
  end
end
