# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Table = Partiduo::Core::TableOutput

describe "Montants et dates des sorties du cœur selon la langue (ADR-005 D7)" do
  it "a une convention pour chaque langue livrée" do
    Partiduo::LOCALES.each { |locale| Partiduo::LocaleFormats::CONVENTIONS.has_key?(locale).should be_true }
  end

  it "sépare milliers et décimales, et ordonne la date, selon la langue" do
    value = BigDecimal.new("-1234567.5")
    day = Time.utc(2026, 9, 7)
    {
      "fr" => {"-1 234 567,50", "07/09/2026"},
      "en" => {"-1,234,567.50", "2026-09-07"},
      "nl" => {"-1.234.567,50", "07-09-2026"},
      "de" => {"-1.234.567,50", "07.09.2026"},
      "es" => {"-1.234.567,50", "07/09/2026"},
      "it" => {"-1.234.567,50", "07/09/2026"},
      "pt" => {"-1 234 567,50", "07/09/2026"},
    }.each do |locale, (amount, date)|
      Table.format_amount(value, locale).should eq(amount)
      Table.format_date(day, locale).should eq(date)
    end
  end

  it "suit le français pour une langue inconnue" do
    Partiduo::LocaleFormats.date(Time.utc(2026, 9, 7), "xx").should eq("07/09/2026")
  end
end
