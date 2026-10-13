# SPDX-License-Identifier: AGPL-3.0-or-later

# Nature d'un poste de prévision (`accounting_forecast_item.nature`) :
# `income` (recette) ou `expense` (dépense), exposée par le contrat
# (`ForecastItemView#nature`, `ForecastReportItemView#nature`, API 0.10.0).
# Les postes existants la reçoivent par la règle appliquée à la création :
# recette si le premier compte de la formule est de la classe 7 (`[701]`,
# `[70%]-[709%]`), dépense sinon (formule vide comprise).
#
# Retour : la colonne disparaît.
class Migration::Accounting::V0015 < Marten::Migration
  depends_on :accounting, "0014_chart_import_permission"

  # Postes de recette d'après leur formule : le premier crochet ouvre un
  # compte de la classe 7. Rejouable.
  FORWARD = <<-SQL
    UPDATE accounting_forecast_item
       SET nature = 'income'
     WHERE nature <> 'income'
       AND formula ~ '^[^[]*[[][[:space:]]*7'
    SQL

  def plan
    add_column :accounting_forecast_item, :nature, :string, max_size: 10, default: "expense"
    execute(FORWARD, "SELECT 1")
    execute(
      "ALTER TABLE accounting_forecast_item ADD CONSTRAINT accounting_forecast_item_nature_check " \
      "CHECK (nature IN ('income', 'expense'))",
      "ALTER TABLE accounting_forecast_item DROP CONSTRAINT IF EXISTS accounting_forecast_item_nature_check"
    )
  end
end
