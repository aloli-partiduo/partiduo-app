# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Csv = Partiduo::Core::CsvImport
private alias Core = Partiduo::Api::Core

private def source(text : String | Bytes, **options) : Core::ImportSource
  content = text.is_a?(String) ? text.to_slice : text
  Core::ImportSource.new(content: content, format: Core::CsvFormat.new(**options))
end

private FIELDS = [
  Core::ImportFieldView.new("number", "accounting.import.fields.number", required: true),
  Core::ImportFieldView.new("label", "accounting.import.fields.label", required: true),
  Core::ImportFieldView.new("parent", "accounting.import.fields.parent"),
]

describe "Partiduo::Core::CsvImport — lecture des fichiers importés (D-OUT-002)" do
  describe ".read" do
    it "découpe selon le format, ignore les lignes demandées et les lignes vides, numérote les enregistrements" do
      records, errors = Csv.read(source("titre\n\n6;Charges\n\"60\";\"Achats ; divers\"\n", skip_rows: 1))
      errors.should be_empty
      records.map(&.line).should eq([3, 4])
      records.last.cells.should eq(["60", "Achats ; divers"])
    end

    it "retire la marque d'ordre des octets et lit le Windows-1252" do
      records, _ = Csv.read(source(Bytes[0xEF, 0xBB, 0xBF] + "été;1".to_slice))
      records.first.cells.should eq(["été", "1"])
      latin = Bytes[0x63, 0x61, 0x66, 0xE9, 0x3B, 0x80] # « café;€ » en Windows-1252
      records, errors = Csv.read(source(latin, encoding: "windows-1252"))
      errors.should be_empty
      records.first.cells.should eq(["café", "€"])
    end

    it "explique un fichier illisible au lieu de deviner" do
      Csv.read(source(Bytes[0x63, 0xE9, 0x3B]))[1].map(&.key).should eq(["core.errors.import.encoding"])
      Csv.read(source("a;\"b\n"))[1].map(&.key).should eq(["core.errors.import.malformed"])
      Csv.read(source("\n \n"))[1].map(&.key).should eq(["core.errors.import.empty"])
      Csv.read(source("a", separator: '#'))[1].map(&.key).should eq(["core.errors.import.separator"])
      Csv.read(source("a", encoding: "latin9"))[1].map(&.key).should eq(["core.errors.import.encoding_unknown"])
      big = Bytes.new(Core::CSV_MAX_BYTES + 1, 'a'.ord.to_u8)
      Csv.read(source(big))[1].map(&.key).should eq(["core.errors.import.too_large"])
    end
  end

  describe ".associate" do
    it "reconnaît un en-tête de clés ou de libellés, dans l'une des langues" do
      records, _ = Csv.read(source("Omschrijving;Numéro;Autre\nAchats;60;x\n"))
      columns, data, header = Csv.associate(records, FIELDS, nil, %w[number label])
      header.should be_true
      columns.should eq(["label", "number", ""])
      data.map(&.line).should eq([2])
    end

    it "prend l'association par défaut sans en-tête, et celle demandée en priorité" do
      records, _ = Csv.read(source("60;Achats;6\n"))
      Csv.associate(records, FIELDS, nil, %w[number label])[0].should eq(["number", "label", ""])
      Csv.associate(records, FIELDS, ["label", "", "number"], %w[number label])[0].should eq(["label", "", "number"])
    end

    it "signale champ inconnu, champ associé deux fois et champ obligatoire absent" do
      errors = Csv.column_errors(["number", "number", "zzz"], FIELDS)
      errors.map(&.key).should eq(["core.errors.import.column_unknown", "core.errors.import.column_duplicate",
                                   "core.errors.import.column_missing"])
      errors.each(&.message.should_not(contain("missing")))
    end
  end

  describe "valeurs" do
    it "lit les décimaux sans flottant, dans les écritures usuelles" do
      Csv.decimal("1 234,56").should eq(BigDecimal.new("1234.56"))
      Csv.decimal("1,234.56").should eq(BigDecimal.new("1234.56"))
      Csv.decimal("1.234,5").should eq(BigDecimal.new("1234.5"))
      Csv.decimal("-3").should eq(BigDecimal.new("-3"))
      Csv.decimal("12,5 €").should be_nil
      Csv.decimal("abc").should be_nil
    end

    it "lit les dates et les booléens" do
      Csv.date("2026-02-28").should eq(Time.utc(2026, 2, 28))
      Csv.date("28/02/2026").should eq(Time.utc(2026, 2, 28))
      Csv.date("31.04.2026").should be_nil
      Csv.boolean("Oui").should be_true
      Csv.boolean("nee").should be_false
      Csv.boolean("peut-être").should be_nil
    end

    it "relit sans l'apostrophe une cellule protégée contre les formules" do
      Csv.unprotect("'+33 1 23").should eq("+33 1 23")
      Csv.unprotect("'abc").should eq("'abc")
    end
  end

  describe "Transaction.dry_run" do
    it "annule tout ce que le bloc a écrit, même réussi" do
      value = Partiduo::Api::Transaction.dry_run do
        ReferentialSpec.category("ESSAI", "customer").id
      end
      value.should be > 0
      Partiduo::Api::Cards.category_by_code(Partiduo::Api::Actor.system, "ESSAI").should be_nil
    end
  end
end
