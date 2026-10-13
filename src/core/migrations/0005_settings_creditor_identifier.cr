# SPDX-License-Identifier: AGPL-3.0-or-later

# Identifiant créancier SEPA de la société (A-SEPA-2) : vide par défaut.
class Migration::Core::V0005 < Marten::Migration
  depends_on :core, "0004_settings_kind"

  def plan
    add_column :core_settings, :creditor_identifier, :string, max_size: 35, default: ""
  end
end
