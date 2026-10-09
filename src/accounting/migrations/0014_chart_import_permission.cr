# SPDX-License-Identifier: AGPL-3.0-or-later

# Import du plan comptable depuis un fichier CSV (DECISIONS D-OUT-004) : la
# permission `accounting.account.import` est accordée aux profils qui
# peuvent déjà modifier le plan comptable (`accounting.account.write`), comme
# le profil ACCOUNTANT créé au provisionnement. Retour : la permission est
# retirée de tous les profils.
class Migration::Accounting::V0014 < Marten::Migration
  depends_on :accounting, "0013_bank_fees_account"
  depends_on :auth, "0002_auth_security"

  def plan
    execute(
      "INSERT INTO auth_profile_permission (profile_id, permission) " \
      "SELECT profile_id, 'accounting.account.import' FROM auth_profile_permission " \
      "WHERE permission = 'accounting.account.write' " \
      "ON CONFLICT (profile_id, permission) DO NOTHING",
      "DELETE FROM auth_profile_permission WHERE permission = 'accounting.account.import'"
    )
  end
end
