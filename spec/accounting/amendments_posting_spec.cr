# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Saisie et reprise ajoutées par les amendements du 13 octobre 2026
# (DECISIONS D-AMD-017 à D-AMD-020) : code de TVA d'une ligne saisie
# (A-IMP-1), référence de l'émetteur (A-IMP-2), lecteur FEC commun
# (A-IMP-4).

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def line(account : String, side : Api::Side, amount : String, vat_rate : String? = nil,
                 vat_role : String? = nil, card : String? = nil) : Api::EntryLineInput
  Api::EntryLineInput.new(account, side, d(amount), card, "", vat_rate, vat_role)
end

private def fec(text : String, encoding : String? = nil, strict : Bool = false) : Api::FecFileView
  Api.read_fec(system, text.to_slice, encoding, strict)
end

private FEC_HEADER = "JournalCode\tJournalLib\tEcritureNum\tEcritureDate\tCompteNum\tCompteLib\tCompAuxNum\tCompAuxLib\t" \
                     "PieceRef\tPieceDate\tEcritureLib\tDebit\tCredit\tEcritureLet\tDateLet\tValidDate\tMontantdevise\tIdevise"

private def fec_row(*values : String) : String
  values.join('\t')
end

describe_module "ACCOUNTING", "Code de TVA d'une ligne saisie (A-IMP-1)" do
  it "écrit des lignes de base et de TVA, le rôle déduit du compte de TVA du taux" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Fournisseur")
    draft = Api.check_document(system, EntrySpec.document("A01", supplier.code, [EntrySpec.item("100", account: "603")])).value!
    deductible = draft.lines.find!(&.vat_role.==("tax")).account_number
    view = Api.post_entry(system, EntrySpec.misc_input([
      line("603", Api::Side::Debit, "100", vat_rate: "NOR"),
      line(deductible, Api::Side::Debit, "20", vat_rate: "nor"),
      line("", Api::Side::Credit, "120", card: supplier.code),
    ], ledger: "A01")).value!
    base = view.lines.find!(&.account_number.==("603"))
    tax = view.lines.find!(&.account_number.==(deductible))
    {base.vat_rate_code, base.vat_role}.should eq({"NOR", "base"})
    {tax.vat_rate_code, tax.vat_role}.should eq({"NOR", "tax"})
    view.lines.find!(&.card_id).vat_role.should be_nil

    totals = Api.vat_totals(system, Api::VatTotalsQuery.new(vat_rates: ["NOR"]))
    totals.sum(d("0"), &.base).should eq(d("100"))
    totals.sum(d("0"), &.tax).should eq(d("20"))
  end

  it "garde un rôle donné, et refuse un rôle inconnu, un rôle sans taux, un taux inconnu" do
    EntrySpec.setup
    explicit = Api.post_entry(system, EntrySpec.misc_input([
      line("681", Api::Side::Debit, "10", vat_rate: "NOR", vat_role: "tax"),
      line("641", Api::Side::Credit, "10"),
    ])).value!
    explicit.lines.first.vat_role.should eq("tax")

    refused = Api.check_entry(system, EntrySpec.misc_input([
      line("681", Api::Side::Debit, "10", vat_rate: "NOR", vat_role: "taxe"),
      line("641", Api::Side::Credit, "10", vat_role: "base"),
    ]))
    refused.errors.map { |error| {error.field, error.key} }.should eq([
      {"lines[0].vat_role", "accounting.errors.entry.vat_role.invalid"},
      {"lines[1].vat_role", "accounting.errors.entry.vat_role.without_rate"},
    ])
    ReferentialSpec.expect_translated(refused)
    Api.check_entry(system, EntrySpec.misc_input([
      line("681", Api::Side::Debit, "10", vat_rate: "XYZ"), line("641", Api::Side::Credit, "10"),
    ])).error_keys.should eq(["accounting.errors.entry.vat_rate.not_found"])
  end
end

describe_module "ACCOUNTING", "Référence de l'émetteur (A-IMP-2)" do
  it "garde la pièce de l'émetteur à côté de la pièce du journal, et la cherche comme elle" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Fournisseur")
    entry = EntrySpec.post_misc([EntrySpec.debit("681", "10"), EntrySpec.credit("641", "10")],
      external_reference: "  ANC-2025/0042 ")
    entry.external_reference.should eq("ANC-2025/0042")
    entry.receipt.should_not eq("ANC-2025/0042")
    invoice = Api.post_purchase(system, EntrySpec.document("A01", supplier.code, [EntrySpec.item("100", account: "603")],
      external_reference: "FA-778")).value!
    Api.entry(system, invoice.id).external_reference.should eq("FA-778")

    Api.entries(system, Api::EntryQuery.new(receipt: "2025/00")).map(&.id).should eq([entry.id])
    Api.entries(system, Api::EntryQuery.new(text: "fa-77")).map(&.id).should eq([invoice.id])
    EntrySpec.post_misc([EntrySpec.debit("681", "1"), EntrySpec.credit("641", "1")]).external_reference.should eq("")
  end

  it "reprend la référence de l'extrait sur chaque écriture, sauf celle propre à une ligne" do
    EntrySpec.setup
    views = Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id,
      date: EntrySpec.date("2026-03-20"), external_reference: "RELEVE-12", lines: [
      Api::PaymentLineInput.new(d("-12"), account: "646"),
      Api::PaymentLineInput.new(d("-5"), account: "646", external_reference: "CB 0457"),
    ])).value!
    views.map(&.external_reference).should eq(["RELEVE-12", "CB 0457"])
  end

  it "refuse une référence de plus de 100 caractères" do
    EntrySpec.setup
    result = Api.check_entry(system, EntrySpec.misc_input([EntrySpec.debit("681", "1"), EntrySpec.credit("641", "1")],
      external_reference: "x" * 101))
    result.errors.map { |error| {error.field, error.key} }
      .should eq([{"external_reference", "accounting.errors.entry.external_reference.too_long"}])
    ReferentialSpec.expect_translated(result)
  end
end

describe_module "ACCOUNTING", "Lecteur FEC commun (A-IMP-4)" do
  it "relit le FEC exporté par le cœur, écriture par écriture" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Fournisseur")
    Api.post_purchase(system, EntrySpec.document("A01", supplier.code, [EntrySpec.item("100", account: "603")])).value!
    EntrySpec.post_misc([EntrySpec.debit("681", "10.5"), EntrySpec.credit("641", "10.5")])
    exported = Api.fec(system, Api::FecQuery.new(date_from: EntrySpec.date("2026-01-01"))).value!

    file = Api.read_fec(system, exported.content, strict: true)
    file.issues.should be_empty
    file.valid?.should be_true
    %w[ISO-8859-15 ASCII].should contain(file.encoding)
    file.entries.size.should eq(2)
    purchase = file.entries.find!(&.journal_code.==("A01"))
    purchase.balanced?.should be_true
    purchase.total_debit.should eq(d("120"))
    purchase.lines.find!(&.aux_number).aux_label.should eq("Fournisseur")
    file.raw_debit.should eq(d("130.5"))
    file.raw_debit.should eq(file.raw_credit)
    file.journals.keys.sort!.should eq(%w[A01 O01])
    file.accounts["681"]?.should_not be_nil
  end

  it "accepte Montant et Sens, le point-virgule, les guillemets, l'échéance et un séparateur terminal" do
    text = [
      "JournalCode;EcritureNum;EcritureDate;CompteNum;EcritureLib;Montant;Sens;DateEcheance;PieceRef;",
      "VT;1;20260115;411000;\"Facture \"\"A\"\"\";1 200,00;D;20260215;F-1;",
      "VT;1;20260115;706000;Facture A;1000,00;C;;F-1;",
      "VT;1;20260115;445710;Facture A;+200;C;;F-1;",
      "VT;1;20260115;471000;Ligne nulle;0;D;;F-1;",
    ].join("\r\n")
    file = fec(text)
    file.issues.should be_empty
    file.separator.should eq(';')
    file.zero_lines.should eq(1)
    entry = file.entries.first
    entry.label.should eq("Facture \"A\"")
    entry.due_date.should eq(Time.utc(2026, 2, 15))
    entry.receipt.should eq("F-1")
    entry.lines.map(&.debit).should eq([d("1200"), d("0"), d("0")])
    # Lecture stricte : point-virgule et zones manquantes refusés.
    fec(text, strict: true).issues.map(&.key).should eq(["accounting.fec_reader.issues.separator_strict"])
  end

  it "compense débit et crédit d'une même ligne et signale les défauts, ligne par ligne" do
    text = [
      FEC_HEADER,
      fec_row("OD", "Divers", "7", "20260301", "681", "Dotations", "", "", "P7", "20260301", "Dot", "15,00", "5,00", "", "", "20260301", "", ""),
      fec_row("OD", "Divers", "7", "20260301", "281", "Amort.", "", "", "P7", "20260301", "Dot", "0,00", "10,00", "", "", "20260301", "", ""),
      fec_row("OD", "Divers", "8", "2026-13-01", "681", "Dotations", "", "", "P8", "", "Dot", "1x", "0", "", "", "", "", ""),
      fec_row("OD", "Divers", "9", "20260302", "681", "Dotations", "", "", "P9", "", "Dot", "3,00", "0", "", "", "", "", ""),
      fec_row("OD", "Divers", "9", "20260303", "401", "Fourn.", "", "", "P9", "", "Dot", "0", "2,00", "", "", "", "", ""),
      "OD\tDivers\ttrop court",
    ].join('\n')
    file = fec(text, strict: true)
    first = file.entries.find!(&.number.==("7"))
    first.lines.first.debit.should eq(d("10"))
    first.lines.first.raw_debit.should eq(d("15"))
    first.lines.first.raw_credit.should eq(d("5"))
    first.balanced?.should be_true
    keys = file.issues.map { |issue| {issue.row, issue.column, issue.key.split('.').last} }
    keys.should contain({4, "EcritureDate", "unreadable_date"})
    keys.should contain({4, "Debit", "unreadable_amount"})
    keys.should contain({6, "EcritureDate", "date_mismatch"})
    keys.should contain({7, "", "field_count"})
    keys.should contain({5, "EcritureNum", "unbalanced"})
    file.valid?.should be_false
    file.issues.each { |issue| issue.message.should_not contain("translation missing") }
  end

  it "reconnaît l'encodage, ou applique celui qu'on impose" do
    text = "JournalCode|EcritureNum|EcritureDate|CompteNum|EcritureLib|Debit|Credit\n" \
           "OD|1|20260105|681|Électricité|10|0\nOD|1|20260105|641|Électricité|0|10\n"
    latin = text.encode("ISO-8859-15")
    file = Api.read_fec(system, latin)
    file.encoding.should eq("ISO-8859-15")
    file.entries.first.label.should eq("Électricité")
    Api.read_fec(system, Bytes[0xEF, 0xBB, 0xBF] + text.to_slice).encoding.should eq("UTF-8")
    windows = "JournalCode|EcritureNum|EcritureDate|CompteNum|EcritureLib|Debit|Credit\n" \
              "OD|1|20260105|681|L’été|10|0\nOD|1|20260105|641|x|0|10\n"
    detected = Api.read_fec(system, windows.encode("WINDOWS-1252"))
    detected.encoding.should eq("WINDOWS-1252")
    detected.entries.first.label.should eq("L’été")
    Api.read_fec(system, latin, "utf-8").issues.map(&.key).should eq(["accounting.fec_reader.issues.invalid_utf8"])
    Api.read_fec(system, latin, "ebcdic").issues.map(&.key).should eq(["accounting.fec_reader.issues.encoding_unknown"])
    Api.read_fec(system, "".to_slice).issues.map(&.key).should eq(["accounting.fec_reader.issues.empty_file"])
    Api.read_fec(system, "JournalCode|Debit\n".to_slice).issues.map(&.column)
      .should eq(%w[EcritureNum EcritureDate CompteNum Debit/Credit])
  end
end
