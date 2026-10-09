# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Accounting
private alias Core = Partiduo::Api::Core

private def importer : Partiduo::Api::Actor
  actor_with("accounting.account.read", "accounting.account.write", "accounting.account.import")
end

private def source(text : String, update : Bool = false, **options) : Core::ImportSource
  Core::ImportSource.new(content: text.to_slice, format: Core::CsvFormat.new(**options), update_existing: update)
end

# Format d'origine : numéro ; libellé ; parent ; type, sans en-tête, classes
# rattachées au parent `0`, sous-comptes avant leur parent.
private LEGACY = <<-CSV
  601;Achats de matières premières;60;CHA
  6;Charges;0;CHA
  60;Achats;6;CHA
  4;Tiers;0;CON
  409;Fournisseurs débiteurs;4;ACTINV
  CSV

describe_module "ACCOUNTING", "Import et export du plan comptable (D-OUT-004)" do
  it "exige l'import et l'écriture du plan comptable" do
    expect_raises(Partiduo::Api::Forbidden) do
      Api.preview_chart_import(actor_with("accounting.account.read", "accounting.account.write"), source(LEGACY))
    end
    expect_raises(Partiduo::Api::Forbidden) { Api.import_chart(actor_with("accounting.account.import"), source(LEGACY)) }
    expect_raises(Partiduo::Api::Forbidden) { Api.export_chart(actor_with) }
  end

  it "lit le format d'origine sans en-tête, parents d'abord quel que soit l'ordre du fichier" do
    view = Api.preview_chart_import(importer, source(LEGACY))
    view.header.should be_false
    view.columns.should eq(%w[number label parent kind])
    view.rows.map(&.line).should eq([1, 2, 3, 4, 5])
    view.rows.map(&.action).uniq!.should eq([Core::ImportAction::Create])
    Api.chart(importer).should be_empty

    Api.import_chart(importer, source(LEGACY)).value!.created_count.should eq(5)
    Api.account(importer, "601").parent_number.should eq("60")
    Api.account(importer, "6").parent_id.should be_nil
    Api.account(importer, "409").kind.should eq(Api::AccountKind::AssetContra)
    Api.account(importer, "601").kind.should eq(Api::AccountKind::Expense)
  end

  it "refuse un compte existant, un type inconnu, un parent absent, avec leur motif" do
    AccountingSpec.create_account("6", "Charges", kind: Api::AccountKind::Expense)
    text = "Numéro;Libellé;Compte parent;Type\n6;Charges;;\n61;Services;;XYZ\n71;Production;7;\n62;Autres services;;expense\n"
    view = Api.preview_chart_import(importer, source(text))
    view.header.should be_true
    view.rows.map(&.action).should eq([Core::ImportAction::Refused, Core::ImportAction::Refused,
                                       Core::ImportAction::Refused, Core::ImportAction::Create])
    view.rows[0].errors.map(&.key).should eq(["accounting.errors.import.number_exists"])
    view.rows[1].errors.map(&.key).should eq(["accounting.errors.import.kind"])
    view.rows[2].errors.map(&.key).should eq(["accounting.errors.account.parent.not_found"])

    Api.import_chart(importer, source(text)).errors.map(&.key).should eq(["core.errors.import.has_refused"])
    Api.chart(importer).size.should eq(1)
    Api.import_chart(importer, source(text), skip_refused: true).value!.created_count.should eq(1)
    Api.account(importer, "62").label.should eq("Autres services")
  end

  it "met à jour sur demande libellé, type et utilisation directe d'un compte existant" do
    AccountingSpec.create_account("6", "Charges", kind: Api::AccountKind::Expense)
    AccountingSpec.create_account("60", "Achat")
    text = "number;label;direct_use\n60;Achats;non\n"
    report = Api.import_chart(importer, source(text, update: true)).value!
    report.updated_count.should eq(1)
    account = Api.account(importer, "60")
    account.label.should eq("Achats")
    account.direct_use.should be_false
    account.parent_number.should eq("6")
  end

  it "exporte le plan au format de l'import, relu dans un dossier vierge à l'identique" do
    AccountingSpec.load
    before = Api.chart(importer).map { |line| {line.account.number, line.account.label, line.account.parent_number, line.account.kind, line.account.direct_use} }
    file = Api.export_chart(importer)
    file.filename.should eq("plan-comptable.csv")
    text = String.new(file.content)
    text.lines.first.should eq("Numéro;Libellé;Compte parent;Type;Utilisation directe")

    Partiduo::Api::Transaction.dry_run do
      Marten::DB::Connection.default.open(&.exec("TRUNCATE accounting_account CASCADE"))
      Api.import_chart(importer, source(text)).value!.created_count.should eq(before.size)
      after = Api.chart(importer).map { |line| {line.account.number, line.account.label, line.account.parent_number, line.account.kind, line.account.direct_use} }
      after.should eq(before)
    end
  end
end
