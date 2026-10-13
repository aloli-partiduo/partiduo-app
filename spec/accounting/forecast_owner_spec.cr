# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Prévision tenue par une extension (A-PER-4, DECISIONS D-AMD-022) : son
# écriture est réservée à la pièce qui la tient, tous la lisent.

private alias Api = Partiduo::Api::Accounting

private def system : Partiduo::Api::Actor
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

# Extension d'essai, active le temps du bloc avec la Comptabilité.
private def with_owner(& : String ->) : Nil
  code = "BUD#{Random::Secure.hex(3).upcase}"
  Partiduo::Modules.register { code code }
  begin
    with_active_modules("accounting,#{code.downcase}") { yield code }
  ensure
    Partiduo::Modules.manifests.delete(code)
  end
end

private def input(owner : String? = nil, name = "Budget 2026") : Api::ForecastInput
  Api::ForecastInput.new(name, EntrySpec.period("2026-01-01").id, EntrySpec.period("2026-12-01").id, owner)
end

describe_module "ACCOUNTING", "Prévision tenue par une extension (A-PER-4)" do
  it "réserve l'écriture à la pièce qui la tient, la laisse lire à tous" do
    with_owner do |owner|
      EntrySpec.setup
      budget = Api.create_forecast(system, input(owner.downcase)).value!
      budget.forecast.owner.should eq(owner)
      budget.forecast.owned?.should be_true
      category = Api.create_forecast_category(system, budget.id, Api::ForecastCategoryInput.new("Logement"), owner: owner).value!
      item = Api.create_forecast_item(system, category.id, Api::ForecastItemInput.new("Loyer", "[6%-s]", d("800")),
        owner: owner).value!

      refused = [
        Api.update_forecast(system, budget.id, input(name: "Autre")),
        Api.delete_forecast(system, budget.id),
        Api.create_forecast_category(system, budget.id, Api::ForecastCategoryInput.new("Divers")),
        Api.update_forecast_category(system, category.id, Api::ForecastCategoryInput.new("Maison")),
        Api.delete_forecast_category(system, category.id),
        Api.check_forecast_item(system, category.id, Api::ForecastItemInput.new("Eau", "[6%-s]")),
        Api.create_forecast_item(system, category.id, Api::ForecastItemInput.new("Eau", "[6%-s]")),
        Api.update_forecast_item(system, item.id, Api::ForecastItemInput.new("Loyer", "[6%-s]", d("900"))),
        Api.delete_forecast_item(system, item.id),
        Api.update_forecast(system, budget.id, input(name: "Autre"), owner: "AUTRE"),
      ]
      refused.each do |result|
        result.errors.map { |error| {error.field, error.key, error.params} }
          .should eq([{"base", "accounting.errors.forecast.owned", {"owner" => owner}}])
      end
      ReferentialSpec.expect_translated(refused.first)

      Api.forecast(actor_with("accounting.report.read"), budget.id).categories.first.items.first.amount.should eq(d("800"))
      Api.forecasts(system).first.owner.should eq(owner)
      Api.update_forecast_item(system, item.id, Api::ForecastItemInput.new("Loyer", "[6%-s]", d("900")), owner: owner)
        .value!.amount.should eq(d("900"))
      # Garder (`nil`), puis libérer (`""`) : tout rédacteur la modifie alors.
      Api.update_forecast(system, budget.id, input(name: "Budget du foyer"), owner: owner).value!.forecast.owner.should eq(owner)
      Api.update_forecast(system, budget.id, input("", "Budget libre"), owner: owner).value!.forecast.owned?.should be_false
      Api.update_forecast(system, budget.id, input(name: "Budget repris")).success?.should be_true
    end
  end

  it "refuse un propriétaire inconnu ou inactif, et copie une prévision tenue sans son propriétaire" do
    with_owner do |owner|
      EntrySpec.setup
      Api.create_forecast(system, input("INCONNU")).error_keys.should eq(["accounting.errors.forecast.owner.unknown"])
      budget = Api.create_forecast(system, input(owner)).value!
      copy = Api.clone_forecast(system, budget.id, "Brouillon").value!
      copy.forecast.owned?.should be_false
      Api.delete_forecast(system, copy.id).success?.should be_true
      Api.delete_forecast(system, budget.id, owner: owner.downcase).success?.should be_true
    end
  end
end
