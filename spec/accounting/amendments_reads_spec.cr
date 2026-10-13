# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lectures de la Comptabilité ajoutées par les amendements du 13 octobre
# 2026 (DECISIONS D-AMD-010 à D-AMD-015) : ligne par son identifiant
# (A-AMO-4), écritures ouvertes d'une nature de fiche (A-SEPA-1), sommes de
# lignes par critère (A-REP-3), totaux par code de TVA (A-REP-5), date de
# paiement ou d'échéance (A-REP-6), solde d'un compte à une date (A-PER-1).

private alias Api = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def date(text : String) : Time
  EntrySpec.date(text)
end

private def sale(customer : Partiduo::Api::Cards::CardView, amount = "1000", day = "2026-03-15",
                 due : String? = nil) : Api::EntryView
  input = EntrySpec.document("V01", customer.code, [EntrySpec.item(amount, account: "706")], day)
  input = input.copy_with(due_date: date(due)) if due
  Api.post_sale(system, input).value!
end

private def purchase(supplier : Partiduo::Api::Cards::CardView, amount = "500", day = "2026-03-10") : Api::EntryView
  Api.post_purchase(system, EntrySpec.document("A01", supplier.code, [EntrySpec.item(amount, account: "603")], day)).value!
end

private def party_line(view : Api::EntryView) : Api::EntryLineView
  view.lines.find! { |line| !line.card_id.nil? }
end

# Utilisateur réel tenu aux droits par journal, sans aucun journal permis.
private def blind(*permissions : String) : Partiduo::Api::Actor
  user_id, actor = AccountingSpec.user_actor("aveugle@example.test", *permissions)
  Partiduo::Api::Auth.set_ledger_security(system, user_id, true).value!
  actor
end

private def pay(card : Partiduo::Api::Cards::CardView, amount : String, day : String,
                match : Array(Int64) = [] of Int64) : Api::EntryView
  Api.post_financial(system, Api::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id, date: date(day),
    lines: [Api::PaymentLineInput.new(d(amount), card: card.code, match_line_ids: match)])).value!.first
end

describe_module "ACCOUNTING", "Lecture d'une ligne d'écriture par son identifiant (A-AMO-4)" do
  it "rend la ligne avec son écriture, et les écritures qui portent une ligne" do
    EntrySpec.setup
    supplier = EntrySpec.card("SUPPLIER", "Fournisseur")
    invoice = purchase(supplier)
    line = invoice.lines.find!(&.account_number.==("603"))
    found = Api.entry_line(system, line.id)
    found.entry_id.should eq(invoice.id)
    found.account_number.should eq("603")
    found.amount.should eq(d("500"))
    invoice.lines.all?(&.entry_id.==(invoice.id)).should be_true
    Api.entries(system, Api::EntryQuery.new(line_ids: [line.id])).map(&.id).should eq([invoice.id])
    Api.entries(system, Api::EntryQuery.new(line_ids: [] of Int64)).should be_empty
  end

  it "refuse une ligne inconnue ou d'un journal que l'acteur ne voit pas" do
    EntrySpec.setup
    invoice = purchase(EntrySpec.card("SUPPLIER", "Fournisseur"))
    expect_raises(Partiduo::Api::NotFound) { Api.entry_line(system, 999_999_i64) }
    expect_raises(Partiduo::Api::NotFound) { Api.entry_line(blind("accounting.entry.read"), invoice.lines.first.id) }
  end
end

describe_module "ACCOUNTING", "Écritures ouvertes d'une nature de fiche (A-SEPA-1)" do
  it "rend les lignes non lettrées de toutes les fiches, en une lecture" do
    EntrySpec.setup
    alpha = EntrySpec.card("SUPPLIER", "Alpha")
    beta = EntrySpec.card("SUPPLIER", "Beta")
    customer = EntrySpec.card("CUSTOMER", "Client")
    paid = purchase(alpha, "100", "2026-02-01")
    pay(alpha, "-120", "2026-02-10", [party_line(paid).id])
    open = purchase(alpha, "200", "2026-03-01")
    other = purchase(beta, "300", "2026-03-05")
    sale(customer)

    items = Api.open_items(system, "supplier", as_of: date("2026-03-31"))
    items.map(&.entry_id).should eq([open.id, other.id])
    first = items.first
    first.card_code.should eq(alpha.code)
    first.side.should eq(Api::Side::Credit)
    first.amount.should eq(d("240"))
    first.signed.should eq(d("-240"))
    first.account_number.should eq(EntrySpec.card_account(alpha))
    first.ledger_code.should eq("A01")
    first.overdue.should be_true
    first.matching_id.should be_nil
    Api.open_items(system, "customer", as_of: date("2026-03-31")).size.should eq(1)
  end

  it "s'arrête à la date de référence et rend, sur demande, les lettrages partiels" do
    EntrySpec.setup
    alpha = EntrySpec.card("SUPPLIER", "Alpha")
    invoice = purchase(alpha, "100", "2026-02-01")
    pay(alpha, "-50", "2026-02-10", [party_line(invoice).id])
    later = purchase(alpha, "10", "2026-04-01")
    paid_later = purchase(alpha, "20", "2026-02-15")
    pay(alpha, "-24", "2026-04-02", [party_line(paid_later).id])

    at_march = Api.open_items(system, "supplier", as_of: date("2026-03-01"))
    at_march.map(&.entry_id).should eq([paid_later.id])
    at_march.first.matching_id.should be_nil
    Api.open_items(system, "supplier", as_of: date("2026-04-30")).map(&.entry_id).should eq([later.id])

    partial = Api.open_items(system, "supplier", as_of: date("2026-04-30"), include_partial: true)
    partial.size.should eq(3)
    lettered = partial.select(&.matching_id)
    lettered.map(&.matching_remaining).uniq!.should eq([d("-70")])
  end
end

describe_module "ACCOUNTING", "Sommes de lignes par critère (A-REP-3)" do
  it "somme par compte, avec contrepartie, fiche, journal et période" do
    EntrySpec.setup
    alpha = EntrySpec.card("CUSTOMER", "Alpha")
    beta = EntrySpec.card("CUSTOMER", "Beta")
    sale(alpha, "1000", "2026-03-15")
    sale(beta, "400", "2026-03-20")
    sale(alpha, "50", "2026-05-02")
    EntrySpec.post_misc([EntrySpec.debit("681", "30"), EntrySpec.credit("706", "30")], "2026-03-25")

    sums = Api.line_sums(system, Api::LineSumQuery.new(account: "706", date_from: date("2026-03-01"),
      date_to: date("2026-03-31")))
    sums.map { |sum| {sum.account_number, sum.debit, sum.credit, sum.lines} }.should eq([{"706", d("0"), d("1430"), 3}])
    sums.first.balance.should eq(d("-1430"))

    by_counterpart = Api.line_sums(system, Api::LineSumQuery.new(account: "706", counterpart_prefix: "41",
      date_to: date("2026-03-31")))
    by_counterpart.first.credit.should eq(d("1400"))

    turnover = Api.line_sums(system, Api::LineSumQuery.new(account: "7", account_prefix: true, card: alpha.code))
    turnover.map { |sum| {sum.account_number, sum.credit} }.should eq([{"706", d("1050")}])
    Api.line_sums(system, Api::LineSumQuery.new(card: "INCONNU")).should be_empty

    sales_ledger = Api.line_sums(system, Api::LineSumQuery.new(account: "706", ledger_kinds: [Api::LedgerKind::Sale]))
    sales_ledger.first.credit.should eq(d("1450"))
    vat = Api.line_sums(system, Api::LineSumQuery.new(account: "4457", account_prefix: true))
    vat.sum(d("0"), &.credit).should eq(d("290"))
  end

  it "ne lit que les journaux visibles, sous accounting.report.read" do
    EntrySpec.setup
    sale(EntrySpec.card("CUSTOMER", "Alpha"))
    Api.line_sums(blind("accounting.report.read"), Api::LineSumQuery.new).should be_empty
    expect_raises(Partiduo::Api::Forbidden) { Api.line_sums(actor_with("accounting.entry.read"), Api::LineSumQuery.new) }
  end
end

describe_module "ACCOUNTING", "Totaux par code de TVA (A-REP-5)" do
  it "rend base et TVA par taux, compte et type de journal" do
    EntrySpec.setup
    customer = EntrySpec.card("CUSTOMER", "Client")
    supplier = EntrySpec.card("SUPPLIER", "Fournisseur")
    sale(customer, "1000")
    purchase(supplier, "500")
    totals = Api.vat_totals(system, Api::VatTotalsQuery.new(date_from: date("2026-03-01"), date_to: date("2026-03-31")))
    sale_base = totals.find! { |row| row.ledger_kind.sale? && row.account_number == "706" }
    sale_base.vat_rate_code.should eq("NOR")
    sale_base.rate.should eq(d("20"))
    sale_base.base.should eq(d("-1000"))
    sale_base.tax.should eq(d("0"))
    totals.select(&.ledger_kind.sale?).sum(d("0"), &.tax).should eq(d("-200"))
    totals.select(&.ledger_kind.purchase?).sum(d("0"), &.base).should eq(d("500"))
    totals.select(&.ledger_kind.purchase?).sum(d("0"), &.tax).should eq(d("100"))

    only_sales = Api.vat_totals(system, Api::VatTotalsQuery.new(ledger_kinds: [Api::LedgerKind::Sale], vat_rates: ["nor"]))
    only_sales.map(&.ledger_kind).uniq!.should eq([Api::LedgerKind::Sale])
    Api.vat_totals(system, Api::VatTotalsQuery.new(vat_rates: ["RED"])).should be_empty
    Api.vat_totals(system, Api::VatTotalsQuery.new(account: "706")).map(&.account_number).uniq!.should eq(["706"])
  end
end

describe_module "ACCOUNTING", "Date de paiement ou d'échéance (A-REP-6)" do
  it "situe une écriture à sa date de paiement, à son échéance, et filtre payées et non payées" do
    EntrySpec.setup
    customer = EntrySpec.card("CUSTOMER", "Client")
    paid = sale(customer, "1000", "2026-03-15", due: "2026-04-15")
    unpaid = sale(customer, "100", "2026-03-20", due: "2026-05-20")
    pay(customer, "1200", "2026-04-10", [party_line(paid).id])

    query = ->(basis : Api::DateBasis, from : String, to : String) do
      Api::EntryQuery.new(ledger_kind: Api::LedgerKind::Sale, date_basis: basis, date_from: date(from), date_to: date(to))
    end
    Api.entries(system, query.call(Api::DateBasis::Operation, "2026-03-01", "2026-03-31")).map(&.id).should eq([paid.id, unpaid.id])
    Api.entries(system, query.call(Api::DateBasis::Payment, "2026-04-01", "2026-04-30")).map(&.id).should eq([paid.id])
    Api.entries(system, query.call(Api::DateBasis::Payment, "2026-03-01", "2026-03-31")).should be_empty
    Api.entries(system, query.call(Api::DateBasis::Due, "2026-05-01", "2026-05-31")).map(&.id).should eq([unpaid.id])
    Api.count_entries(system, Api::EntryQuery.new(paid: true)).should eq(2) # la facture et son paiement
    Api.entries(system, Api::EntryQuery.new(paid: false)).map(&.id).should eq([unpaid.id])
    # Une écriture sans ligne de tiers n'est ni payée ni non payée.
    EntrySpec.post_misc([EntrySpec.debit("681", "5"), EntrySpec.credit("641", "5")])
    Api.entries(system, Api::EntryQuery.new(paid: false)).map(&.id).should eq([unpaid.id])
  end

  it "applique la même règle à la balance générale et aux sommes de lignes" do
    EntrySpec.setup
    customer = EntrySpec.card("CUSTOMER", "Client")
    paid = sale(customer, "1000", "2026-03-15")
    sale(customer, "100", "2026-03-20")
    pay(customer, "1200", "2026-04-10", [party_line(paid).id])

    april = Api.trial_balance(system, Api::TrialBalanceQuery.new(date_from: date("2026-04-01"), date_to: date("2026-04-30"),
      date_basis: Api::DateBasis::Payment, ledger_kinds: [Api::LedgerKind::Sale]))
    april.rows.find!(&.number.==("706")).credit.should eq(d("1000"))
    march = Api.trial_balance(system, Api::TrialBalanceQuery.new(date_from: date("2026-03-01"), date_to: date("2026-03-31"),
      ledger_kinds: [Api::LedgerKind::Sale]))
    march.rows.find!(&.number.==("706")).credit.should eq(d("1100"))
    unpaid = Api.trial_balance(system, Api::TrialBalanceQuery.new(date_to: date("2026-12-31"), paid: false,
      ledger_kinds: [Api::LedgerKind::Sale]))
    unpaid.rows.find!(&.number.==("706")).credit.should eq(d("100"))
    collected = Api.line_sums(system, Api::LineSumQuery.new(account: "4457", account_prefix: true,
      date_basis: Api::DateBasis::Payment, date_from: date("2026-04-01"), date_to: date("2026-04-30")))
    collected.sum(d("0"), &.credit).should eq(d("200"))
  end
end

describe_module "ACCOUNTING", "Solde d'un compte à une date (A-PER-1)" do
  it "rend le solde du compte, ou de ses sous-comptes, sans lire ses lignes" do
    EntrySpec.setup
    EntrySpec.post_misc([EntrySpec.debit("681", "100"), EntrySpec.credit("641", "100")], "2026-02-01")
    EntrySpec.post_misc([EntrySpec.debit("641", "30"), EntrySpec.credit("681", "30")], "2026-03-01")
    Api.account_balance(system, "681", date("2026-02-28")).should eq(d("100"))
    Api.account_balance(system, "681", date("2026-03-31")).should eq(d("70"))
    Api.account_balance(system, "681", date("2026-01-31")).should eq(d("0"))
    statement = Api.account_statement(system, Api::StatementQuery.new(account: "681", date_to: date("2026-03-31")))
    Api.account_balance(system, "681", date("2026-03-31")).should eq(statement.balance)
    Api.account_balance(system, "68", date("2026-03-31"), prefix: true).should eq(d("70"))
    Api.account_balance(system, "641", date("2026-03-31")).should eq(d("-70"))
    expect_raises(Partiduo::Api::NotFound) { Api.account_balance(system, "999999") }
    Api.account_balance(blind("accounting.entry.read"), "681", date("2026-03-31")).should eq(d("0"))
  end
end
