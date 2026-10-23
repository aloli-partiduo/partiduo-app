# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  # Séparateurs des montants et motif des dates des sorties du cœur (PDF,
  # CSV, exports), par langue (ADR-005 D7) : `1 234,56` et `15/09/2026` en
  # français, `1,234.56` et `2026-09-15` en anglais, `1.234,56` et
  # `15-09-2026` en néerlandais, `1.234,56` et `15.09.2026` en allemand…
  # Une langue inconnue suit le français. L'interface a ses propres
  # conventions, qui tiennent compte du pays (`PartiduoUi::Format`).
  module LocaleFormats
    # Séparateur de milliers, séparateur décimal, motif de date.
    record Convention, thousands : String, decimal : String, date : String

    CONVENTIONS = {
      "fr" => Convention.new(" ", ",", "%d/%m/%Y"),
      "en" => Convention.new(",", ".", "%Y-%m-%d"),
      "nl" => Convention.new(".", ",", "%d-%m-%Y"),
      "de" => Convention.new(".", ",", "%d.%m.%Y"),
      "es" => Convention.new(".", ",", "%d/%m/%Y"),
      "it" => Convention.new(".", ",", "%d/%m/%Y"),
      "pt" => Convention.new(" ", ",", "%d/%m/%Y"),
    }

    def self.for(locale : String) : Convention
      CONVENTIONS[locale]? || CONVENTIONS["fr"]
    end

    # Séparateur de milliers et séparateur décimal de la langue.
    def self.separators(locale : String) : {String, String}
      convention = self.for(locale)
      {convention.thousands, convention.decimal}
    end

    def self.date(value : Time, locale : String) : String
      value.to_s(self.for(locale).date)
    end
  end
end
