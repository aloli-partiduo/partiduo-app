# SPDX-License-Identifier: AGPL-3.0-or-later

# Pièces actives au provisionnement (D-AMD-034) : vide (`NULL`) pour les
# dossiers déjà provisionnés, qui gardent `PARTIDUO_MODULES` ou le défaut.
class Migration::Core::V0008 < Marten::Migration
  depends_on :core, "0007_approvals"

  def plan
    add_column :core_settings, :provisioned_modules, :text, null: true
  end
end
