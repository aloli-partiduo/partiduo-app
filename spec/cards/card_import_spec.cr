# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Cards
private alias Core = Partiduo::Api::Core
private alias R = ReferentialSpec

private def importer : Partiduo::Api::Actor
  actor_with("cards.card.read", "cards.card.write", "cards.card.import")
end

private def source(text : String, columns : Array(String)? = nil, update : Bool = false) : Core::ImportSource
  Core::ImportSource.new(content: text.to_slice, columns: columns, update_existing: update)
end

private def customers : Api::CategoryView
  R.category("CUSTOMER", "customer", "Clients", [
    Api::AttributeInput.new(key: "ref", label: "Référence interne", value_type: "text"),
    Api::AttributeInput.new(key: "limit", label: "Encours autorisé", value_type: "number", decimals: 2),
  ])
end

private CSV_CUSTOMERS = <<-CSV
  Nom;Quick code;SIREN;Localité;Pays;Encours autorisé;Active
  Boulangerie Martin;MARTIN;732 829 320;Paris;FR;1 500,50;oui
  Garage Morel;;123456789;Lyon;FR;;oui
  Café Durand;;;Lille;FR;abc;peut-être
  CSV

describe "Partiduo::Api::Cards — import de fiches (D-OUT-003)" do
  it "exige l'import et l'écriture des fiches" do
    category = customers
    expect_raises(Partiduo::Api::Forbidden) do
      Api.preview_card_import(actor_with("cards.card.read", "cards.card.write"), category.id, source("Nom\nA\n"))
    end
    expect_raises(Partiduo::Api::Forbidden) do
      Api.import_cards(actor_with("cards.card.import"), category.id, source("Nom\nA\n"))
    end
  end

  it "propose les champs de la nature de la catégorie et ses attributs propres" do
    keys = Api.card_import_fields(importer, customers.id).map(&.key)
    keys.should contain("customer_nature")
    keys.should contain("address.city")
    keys.should contain("extra.limit")
    keys.should_not contain("sale_price")
    items = Api.card_import_fields(importer, R.category("SALE", "item", "Ventes").id).map(&.key)
    items.should contain("sale_price")
    items.should_not contain("siren")
  end

  it "montre un aperçu ligne à ligne, motifs des refus compris, sans rien enregistrer" do
    category = customers
    R.capture_events("card.saved") do |events|
      logged = Partiduo::Modules::EventLog.all.count
      view = Api.preview_card_import(importer, category.id, source(CSV_CUSTOMERS))
      view.header.should be_true
      view.columns.should eq(["name", "code", "siren", "address.city", "address.country_code", "extra.limit", "enabled"])
      view.rows.map(&.line).should eq([2, 3, 4])
      view.rows.map(&.action).should eq([Core::ImportAction::Create, Core::ImportAction::Refused, Core::ImportAction::Refused])
      view.rows[0].reference.should eq("MARTIN")
      view.rows[1].errors.map(&.key).should eq(["cards.errors.card.siren.invalid"])
      view.rows[2].errors.map(&.key).should eq(["core.errors.import.boolean", "core.errors.import.decimal"])
      view.rows[2].errors.map(&.field).should eq(["enabled", "extra.limit"])
      view.created_count.should eq(1)
      view.refused_count.should eq(2)
      view.importable?.should be_true
      # Les abonnés ont vu l'essai, annulé avec lui : rien n'est resté au journal.
      events.size.should eq(1)
      Partiduo::Modules::EventLog.all.count.should eq(logged)
    end
    Api.count_cards(importer, Api::CardQuery.new(category_id: category.id)).should eq(0)
  end

  it "n'importe rien tant qu'une ligne est refusée, puis seulement les lignes acceptées sur confirmation" do
    category = customers
    result = Api.import_cards(importer, category.id, source(CSV_CUSTOMERS))
    result.failure?.should be_true
    result.errors.map(&.key).should eq(["core.errors.import.has_refused"])
    result.errors.first.message.should contain("2 lignes")
    Api.count_cards(importer, Api::CardQuery.new(category_id: category.id)).should eq(0)

    report = Api.import_cards(importer, category.id, source(CSV_CUSTOMERS), skip_refused: true).value!
    report.created_count.should eq(1)
    report.refused_count.should eq(2)
    card = R.present(Api.card_by_code(importer, "MARTIN"))
    card.siren.should eq("732829320")
    card.extra["limit"].should eq(JSON::Any.new("1500.5"))
    R.present(card.address).city.should eq("Paris")
  end

  it "refuse une fiche existante, ou la met à jour sur demande avec les seules cellules remplies" do
    category = customers
    existing = R.card(category.id, "Martin", code: "MARTIN", email: "compta@martin.example", siren: "732829320")
    text = "Quick code;Nom;Courriel;SIREN\nmartin;Boulangerie Martin;;\n"
    refused = Api.preview_card_import(importer, category.id, source(text))
    refused.rows.first.errors.map(&.key).should eq(["cards.errors.import.code_exists"])

    report = Api.import_cards(importer, category.id, source(text, update: true)).value!
    report.updated_count.should eq(1)
    card = Api.card(importer, existing.id)
    card.name.should eq("Boulangerie Martin")
    card.email.should eq("compta@martin.example")
    card.siren.should eq("732829320")

    other = R.category("SUPPLIER", "supplier", "Fournisseurs")
    view = Api.preview_card_import(importer, other.id, source(text, update: true))
    view.rows.first.errors.map(&.key).should eq(["cards.errors.import.other_category"])
  end

  it "signale une association de colonnes incomplète ou en double, sans traiter les lignes" do
    category = customers
    view = Api.preview_card_import(importer, category.id, source("A;B\n", columns: ["siren", "siren"]))
    view.errors.map(&.key).should eq(["core.errors.import.column_duplicate", "core.errors.import.column_missing"])
    view.rows.should be_empty
    view.importable?.should be_false
    Api.import_cards(importer, category.id, source("A;B\n", columns: ["siren", "siren"])).failure?.should be_true
  end

  it "fait d'un fournisseur nommé par ses nom et prénoms une personne physique" do
    category = R.category("SUPPLIER", "supplier", "Fournisseurs")
    text = "Nom de famille;Prénoms;Date de naissance\nDurand;Paul;03/05/1970\n"
    Api.import_cards(importer, category.id, source(text)).value!
    card = Api.cards(importer, Api::CardQuery.new(category_id: category.id)).first
    card.supplier_nature.should eq("individual")
    card.name.should eq("Durand Paul")
    card.birth_date.should eq(Time.utc(1970, 5, 3))
  end

  it "importe des articles avec prix décimaux et taux de TVA par son code" do
    rate = R.vat_rate("NOR", "20")
    category = R.category("SALE", "item", "Ventes")
    text = "Nom;Prix de vente;Taux de TVA;Unité\nCroissant;1,10;NOR;C62\nPain;2,5;XYZ;C62\n"
    view = Api.preview_card_import(importer, category.id, source(text))
    view.rows[1].errors.map(&.key).should eq(["cards.errors.import.vat_rate_unknown"])
    view.rows[1].errors.first.field.should eq("vat_rate")
    Api.import_cards(importer, category.id, source(text), skip_refused: true).value!
    card = Api.cards(importer, Api::CardQuery.new(category_id: category.id)).first
    card.sale_price.should eq(BigDecimal.new("1.10"))
    card.vat_rate_id.should eq(rate.id)
  end

  it "exporte une catégorie au format de l'import, relu tel quel" do
    category = customers
    R.card(category.id, "Martin", code: "MARTIN", phone: "+33 1 23 45 67 89",
      extra: {"limit" => JSON::Any.new("250")},
      address: Api::AddressInput.new(line1: "1 rue du Four", postcode: "75006", city: "Paris", country_code: "FR"))
    file = Api.export_cards(importer, category.id)
    file.filename.should eq("fiches-CUSTOMER.csv")
    text = String.new(file.content)
    text.lines.first.should start_with("Nom;Quick code;Description;Active")
    text.should contain("'+33 1 23 45 67 89")

    view = Api.preview_card_import(importer, category.id, source(text, update: true))
    view.header.should be_true
    view.rows.map(&.action).should eq([Core::ImportAction::Update])
    Api.import_cards(importer, category.id, source(text, update: true)).value!
    Api.card_by_code(importer, "MARTIN").try(&.phone).should eq("+33 1 23 45 67 89")
  end
end

describe_module "ACCOUNTING", "Import de fiches avec leur compte (D-OUT-003)" do
  it "crée la fiche avec le compte demandé, droit de la Comptabilité exigé" do
    AccountingSpec.load
    category = R.present(Api.category_by_code(R.system, "CUSTOMER"))
    text = "Nom;Compte comptable\nMartin;4111\n"
    view = Api.preview_card_import(importer, category.id, source(text))
    view.rows.first.errors.map(&.key).should eq(["cards.errors.import.account_forbidden"])

    writer = actor_with("cards.card.read", "cards.card.write", "cards.card.import", "accounting.account.write",
      "accounting.account.read")
    Api.import_cards(writer, category.id, source(text)).value!
    card = Api.cards(writer, Api::CardQuery.new(category_id: category.id)).first
    R.present(Partiduo::Api::Accounting.card_account(writer, card.id)).account.number.should eq("4111")
  end
end
