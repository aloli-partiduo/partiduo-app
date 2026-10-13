# SPDX-License-Identifier: AGPL-3.0-or-later

# Référence de l'émetteur sur une écriture (A-IMP-2) : la pièce du logiciel
# ou du document d'origine, gardée à côté de la pièce du journal ; vide pour
# les écritures existantes.
class Migration::Accounting::V0016 < Marten::Migration
  depends_on :accounting, "0015_forecast_item_nature"

  def plan
    add_column :accounting_entry, :external_reference, :string, max_size: 100, default: ""
  end
end
