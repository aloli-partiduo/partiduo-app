# SPDX-License-Identifier: AGPL-3.0-or-later

# Type de dossier (ADR-011 A3) : `company` pour les dossiers existants, qui
# sont tous des dossiers d'entreprise.
class Migration::Core::V0004 < Marten::Migration
  depends_on :core, "0003_period_guard_fiscal_year_move"

  def plan
    add_column :core_settings, :kind, :string, max_size: 32, default: "company"
  end
end
