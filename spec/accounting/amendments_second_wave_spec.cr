# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Manques du contrat relevés par la deuxième vague des extensions (DECISIONS
# D-AMD-037) : ajouter une écriture à un relevé déjà pointé sans changer son
# identifiant (`partiduo-bankimport`, `partiduo-perso`), date de paiement ou
# d'échéance et « payé / non payé » dans la balance des tiers
# (`partiduo-reports`), lecteur FEC sans Comptabilité active
# (`partiduo-migrate`).

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

private def f01 : Int64
  EntrySpec.ledger("F01").id
end

# Une opération en banque, sur un compte de charge.
private def bank(amount : String, day = "2026-03-20") : Api::EntryView
  Api.post_financial(system, Api::FinancialInput.new(ledger_id: f01, date: date(day),
    lines: [Api::PaymentLineInput.new(d(amount), account: "646")])).value!.first
end

private def sale(customer : Partiduo::Api::Cards::CardView, amount : String, day : String) : Api::EntryView
  Api.post_sale(system, EntrySpec.document("V01", customer.code, [EntrySpec.item(amount, account: "706")], day)).value!
end

private def pay(card : Partiduo::Api::Cards::CardView, amount : String, day : String, match : Array(Int64)) : Api::EntryView
  Api.post_financial(system, Api::FinancialInput.new(ledger_id: f01, date: date(day),
    lines: [Api::PaymentLineInput.new(d(amount), card: card.code, match_line_ids: match)])).value!.first
end

describe_module "ACCOUNTING", "Ajout d'écritures à un relevé rapproché (D-AMD-037)" do
  it "ajoute l'extourne et l'écriture qui corrige, sans changer le relevé" do
    EntrySpec.setup
    first, second = bank("1200"), bank("-300.50")
    statement = Api.reconcile(system, Api::ReconcileInput.new(ledger_id: f01, reference: "R-001",
      entry_ids: [first.id, second.id], start_balance: d("100"), end_balance: d("999.50"))).value!

    reversal = Api.cancel_entry(system, Api::CancelEntryInput.new(entry_id: second.id)).value!
    corrected = bank("-300.50", "2026-03-21")
    added = Api.add_to_statement(system, statement.id, [reversal.id, corrected.id, corrected.id]).value!
    {added.id, added.reference, added.amount, added.entry_count}.should eq({statement.id, "R-001", d("899.5"), 4})
    added.start_balance.should eq(d("100"))
    Api.bank_statement(system, statement.id).lines.map(&.entry_id).sort!
      .should eq([first.id, second.id, reversal.id, corrected.id].sort!)
    Api.reconciliation(system, f01).unreconciled.should be_empty
  end

  it "refuse un total qui ne tombe plus juste, une écriture rapprochée ou d'un autre journal, une liste vide" do
    EntrySpec.setup
    first = bank("1200")
    statement = Api.reconcile(system, Api::ReconcileInput.new(ledger_id: f01, reference: "R-001",
      entry_ids: [first.id], start_balance: d("0"), end_balance: d("1200"))).value!
    lone = bank("-12")
    mismatch = Api.add_to_statement(system, statement.id, [lone.id])
    mismatch.error_keys.should eq(["accounting.errors.reconciliation.mismatch"])
    mismatch.errors.first.params.should eq({"expected" => "1200.00", "selected" => "1188.00", "difference" => "-12.00"})
    Api.add_to_statement(system, statement.id, [first.id]).error_keys
      .should eq(["accounting.errors.reconciliation.entries.invalid"])
    misc = EntrySpec.post_misc([EntrySpec.debit("646", "5"), EntrySpec.credit("510001", "5")])
    Api.add_to_statement(system, statement.id, [misc.id]).errors.first.params.should eq({"id" => misc.id.to_s})
    Api.add_to_statement(system, statement.id, [] of Int64).error_keys
      .should eq(["accounting.errors.reconciliation.entries.blank"])
    Api.bank_statement(system, statement.id).statement.entry_count.should eq(1)

    # Relevé sans soldes : pas de contrôle du total (règle de `reconcile`).
    open = Api.reconcile(system, Api::ReconcileInput.new(ledger_id: f01, reference: "R-002", entry_ids: [lone.id])).value!
    Api.add_to_statement(system, open.id, [bank("7").id]).value!.amount.should eq(d("-5"))
  end

  it "exige le droit de lettrer et un relevé connu" do
    EntrySpec.setup
    statement = Api.reconcile(system, Api::ReconcileInput.new(ledger_id: f01, reference: "R-001",
      entry_ids: [bank("10").id])).value!
    reader = Partiduo::Api::Actor.user(1_i64, ["accounting.entry.read"], level: 3)
    expect_raises(Partiduo::Api::Forbidden) { Api.add_to_statement(reader, statement.id, [bank("1").id]) }
    expect_raises(Partiduo::Api::NotFound) { Api.add_to_statement(system, 999_999_i64, [bank("1").id]) }
  end
end

describe_module "ACCOUNTING", "Balance des tiers par date de paiement, payé / non payé (D-AMD-037)" do
  it "situe les écritures par leur paiement et filtre les fiches payées" do
    EntrySpec.setup
    alpha = EntrySpec.card("CUSTOMER", "Alpha")
    beta = EntrySpec.card("CUSTOMER", "Beta")
    paid = sale(alpha, "1000", "2026-03-15")
    sale(beta, "100", "2026-03-20")
    pay(alpha, "1200", "2026-04-10", [paid.lines.find! { |line| !line.card_id.nil? }.id])

    query = ->(basis : Api::DateBasis, paid_filter : Bool?) do
      Api.auxiliary_balance(system, Api::AuxiliaryBalanceQuery.new(date_from: date("2026-04-01"),
        date_to: date("2026-04-30"), ledger_ids: [EntrySpec.ledger("V01").id], date_basis: basis, paid: paid_filter))
    end
    by_payment = query.call(Api::DateBasis::Payment, nil)
    by_payment.rows.map(&.card_name).should eq(["Alpha"])
    by_payment.rows.first.debit.should eq(d("1200"))
    query.call(Api::DateBasis::Operation, nil).rows.sum(&.lines).should eq(0)

    unpaid = Api.auxiliary_balance(system, Api::AuxiliaryBalanceQuery.new(date_to: date("2026-12-31"), paid: false))
    unpaid.rows.map(&.card_name).should eq(["Beta"])
    unpaid.total.closing.debit.should eq(d("120"))
    settled = Api.auxiliary_balance(system, Api::AuxiliaryBalanceQuery.new(date_to: date("2026-12-31"), paid: true))
    settled.rows.map(&.card_name).should eq(["Alpha"])
  end
end

describe "Lecteur FEC sans Comptabilité active (D-AMD-037)" do
  it "lit et contrôle un FEC, même quand la Comptabilité est inactive" do
    text = "JournalCode|EcritureNum|EcritureDate|CompteNum|EcritureLib|Debit|Credit\n" \
           "OD|1|20260105|681|Dotation|10|0\nOD|1|20260105|641|Dotation|0|10\n"
    with_active_modules("none") do
      Partiduo::Modules.active?("ACCOUNTING").should be_false
      file = Partiduo::Api::Accounting.read_fec(Partiduo::Api::Actor.system, text.to_slice)
      file.valid?.should be_true
      file.entries.size.should eq(1)
      expect_raises(Partiduo::Api::Forbidden) do
        Partiduo::Api::Accounting.read_fec(Partiduo::Api::Actor.anonymous, text.to_slice)
      end
    end
  end
end
