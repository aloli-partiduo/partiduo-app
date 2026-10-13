# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Immobilisations de la 2035 fournies par une extension (A-AMO-3,
# DECISIONS D-AMD-023) : la 2035 lit la source active au lieu du registre
# linéaire du module.

private alias Api = Partiduo::Api::Liberal
private alias L = LiberalSpec

private def row(number : String, amount : String, prior : String, year : String) : Api::DepreciationRowView
  Api::DepreciationRowView.new(asset_id: 1_i64, number: number, label: "Échographe", category: "equipment",
    acquired_on: L.date("2025-03-01"), service_on: L.date("2025-03-01"), amount: L.d(amount), duration_years: 5,
    rate: L.d("40"), prior: L.d(prior), year_amount: L.d(year), disposed_on: nil)
end

private def with_source(provide : Bool = true, & : String ->) : Nil
  code = "AMO#{Random::Secure.hex(3).upcase}"
  Partiduo::Modules.register { code code }
  Api.register_asset_source(code) do |_actor, year|
    next unless provide && year == 2026
    disposal = Api::DisposalResultView.new(asset_id: 2_i64, number: "D-1", label: "Ancien fauteuil",
      date: L.date("2026-06-30"), price: L.d("500"), net_value: L.d("300"), depreciation: L.d("700"),
      short_term: L.d("200"), long_term: L.d("0"))
    Api::AssetSourceView.new([row("E-1", "10000", "3333.33", "2666.67")], [disposal], "liberal.module.name")
  end
  begin
    with_active_modules("liberal,#{code.downcase}") { yield code }
  ensure
    Api.unregister_asset_source(code)
    Partiduo::Modules.manifests.delete(code)
  end
end

describe_module "LIBERAL", "Immobilisations de la 2035 fournies par une extension (A-AMO-3)" do
  it "prépare la 2035 avec les immobilisations de la source, et signale le registre écarté" do
    with_source do |code|
      L.setup
      L.asset("2026-04-01", "3000", 3)
      view = Api.tax_return(L.system, 2026)
      view.asset_source.should eq(code)
      view.assets.map(&.number).should eq(["E-1"])
      view.amount("depreciation").should eq(L.d("2667"))
      view.amount("assets_prior_depreciation").should eq(L.d("3333"))
      view.amount("disposals_price").should eq(L.d("500"))
      view.amount("short_term_gains").should eq(L.d("200"))
      ignored = view.controls.find!(&.key.==("liberal.controls.asset_register_ignored"))
      ignored.severity.should eq("warning")
      ignored.params["lines"].should eq("1")
      I18n.t(ignored.key, ignored.params).should contain("1")
    end
  end

  it "garde le registre du module sans source active, ou quand la source ne tient pas l'année" do
    with_source(provide: false) do
      L.setup
      L.asset("2026-04-01", "3000", 3)
      view = Api.tax_return(L.system, 2026)
      view.asset_source.should eq("")
      view.assets.size.should eq(1)
    end
    expect_raises(ArgumentError, /code de pièce invalide/) { Api.register_asset_source("amortis") { |_a, _y| nil } }
  end
end
