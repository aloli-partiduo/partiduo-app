# SPDX-License-Identifier: AGPL-3.0-or-later

# Prévision tenue par une extension (A-PER-4) : code du registre de la pièce
# qui en réserve l'écriture (`PERSO` pour le budget d'un foyer) ; vide pour
# les prévisions existantes, que tout rédacteur modifie.
class Migration::Accounting::V0017 < Marten::Migration
  depends_on :accounting, "0016_entry_external_reference"

  def plan
    add_column :accounting_forecast, :owner, :string, max_size: 32, default: ""
  end
end
