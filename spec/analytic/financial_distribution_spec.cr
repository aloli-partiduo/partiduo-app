# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Extrait financier ventilé (A-IMP-3, DECISIONS D-AMD-019) : variante
# ventilée de `post_financial`, comme `post_entry`, `post_purchase` et
# `post_sale`.

private alias Api = Partiduo::Api::Analytic
private alias Acc = Partiduo::Api::Accounting

private def system
  Partiduo::Api::Actor.system
end

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def statement(lines : Array(Acc::PaymentLineInput)) : Acc::FinancialInput
  Acc::FinancialInput.new(ledger_id: EntrySpec.ledger("F01").id, date: EntrySpec.date("2026-03-20"), lines: lines)
end

describe_module "ANALYTIC", "Extrait financier ventilé (A-IMP-3)" do
  it "ventile la contrepartie de chaque ligne de l'extrait, dans la transaction de l'extrait" do
    data = AnalyticSpec.setup
    customer = EntrySpec.card("CUSTOMER", "Client")
    views = Api.post_financial(system, statement([
      Acc::PaymentLineInput.new(d("1200"), card: customer.code),
      Acc::PaymentLineInput.new(d("-12"), account: "627"),
      Acc::PaymentLineInput.new(d("-30"), account: "646"),
    ]), [
      Api::InputDistributionInput.new(1, [AnalyticSpec.row("12", data[:workshop], data[:p1])]),
      Api::InputDistributionInput.new(2, post_ids: [data[:sale].id, data[:p2].id]),
    ]).value!
    views.size.should eq(3)
    fees = Api.entry_distributions(system, views[1].id)
    fees.map { |item| {item.account_number, item.line_amount} }.uniq!.should eq([{"627", d("12")}])
    fees.sum(d("0"), &.total_for(data[:activity].id)).should eq(d("12"))
    fees.sum(d("0"), &.total_for(data[:project].id)).should eq(d("12"))
    other = Api.entry_distributions(system, views[2].id)
    other.sum(d("0"), &.total_for(data[:activity].id)).should eq(d("30"))
    other.sum(d("0"), &.total_for(data[:project].id)).should eq(d("30"))
    Api.entry_distributions(system, views[0].id).should be_empty
    views[1].lines.find!(&.account_number.==("627")).input_index.should eq(1)
  end

  it "n'enregistre rien si une ventilation est refusée, et cite la ventilation en cause" do
    data = AnalyticSpec.setup
    before = Acc.count_entries(system)
    result = Api.post_financial(system, statement([
      Acc::PaymentLineInput.new(d("-12"), account: "627"),
    ]), [
      Api::InputDistributionInput.new(0, [AnalyticSpec.row("13", data[:workshop])]),
      Api::InputDistributionInput.new(5, post_ids: [data[:sale].id]),
    ])
    result.failure?.should be_true
    result.errors.map(&.field).should contain("distributions[1].input_index")
    result.errors.any?(&.field.starts_with?("distributions[0]")).should be_true
    Acc.count_entries(system).should eq(before)
  end

  it "exige en mode obligatoire la ventilation de chaque contrepartie d'un compte ventilé" do
    AnalyticSpec.setup
    AnalyticSpec.mandatory!
    result = Api.post_financial(system, statement([Acc::PaymentLineInput.new(d("-12"), account: "627")]),
      [] of Api::InputDistributionInput)
    result.errors.map(&.field).should contain("distributions[input=0]")
  end
end
