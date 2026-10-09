# SPDX-License-Identifier: AGPL-3.0-or-later

# Jeu de données initial du socle (convention C6) : la devise de tenue. Les
# régimes FR et BE tiennent tous deux leur comptabilité en euros (règle d'origine :
# `currency.id = 0`, `EUR`).
Partiduo::Api::InitialData.register("CORE", "base_currency", order: 2) do |context|
  name = I18n.with_locale(Partiduo::LOCALES.includes?(context.locale) ? context.locale : "fr") do
    I18n.t("core.currencies.eur")
  end
  Partiduo::Api::Core.ensure_base_currency(context.actor, "EUR", name)
end

# Types de dossier du cœur (ADR-011 A3) : l'entreprise, plan du régime ; le
# foyer, plan réduit, avec la Comptabilité et sans aucun module propre aux
# entreprises (ADR-011 D2).
Partiduo::Api::InitialData.register_kind(Partiduo::Api::InitialData::COMPANY, "CORE")
Partiduo::Api::InitialData.register_kind(Partiduo::Api::InitialData::HOUSEHOLD, "CORE",
  chart: Partiduo::Api::InitialData::HOUSEHOLD, required: %w[ACCOUNTING],
  excluded: %w[INVOICING MICRO LIBERAL STOCK FOLLOWUP ANALYTIC])
