# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Partiduo::Api::Invoicing

# Défauts de traduction d'un texte produit : marqueur de clé absente,
# interpolation non résolue.
private def untranslated(text : String) : Array(String)
  found = [] of String
  text.scan(/(?:missing translation|translation missing):\s*[\w.\-]+/i) { |match| found << match[0] }
  text.scan(/%\{\w+\}/) { |match| found << match[0] }
  found
end

# Documents, PDF (Factur-X compris), courriel d'envoi et relances produits
# dans chaque langue livrée (ADR-005 D7), la langue étant celle du
# document. Le texte des courriels ne doit contenir ni « missing
# translation » ni interpolation non résolue ; chaque clé cherchée pendant
# la production existe dans les trois langues (sonde des traductions,
# spec/support/translation_probe.cr).
describe_module "INVOICING", "Facturation — sorties dans chaque langue" do
  Partiduo::LOCALES.each do |locale|
    it "produit les PDF, le courriel d'envoi et les relances en #{locale}, sans traduction absente" do
      transport = Api::MemoryTransport.new
      previous = Api.mail_transport
      Api.mail_transport = transport
      begin
        setup = InvoicingSpec.setup
        Api.update_settings(InvoicingSpec.actor, Api.settings(InvoicingSpec.actor).to_input
          .copy_with(late_penalty_rate: BigDecimal.new("10"))).value!
        invoice = InvoicingSpec.issued(setup, on: "2026-07-01", locale: locale)
        documents = [invoice,
                     InvoicingSpec.draft(setup, "quote", locale: locale),
                     InvoicingSpec.issued(setup, "credit_note", on: "2026-07-02", locale: locale,
                       credited_document_id: invoice.id, lines: [InvoicingSpec.line(setup, "1")])]
        documents.each do |document|
          document.locale.should eq(locale)
          Api.document_pdf(InvoicingSpec.actor, document.id).content.size.should be > 0
        end

        Api.send_document(InvoicingSpec.actor, invoice.id, Api::SendInput.new(to: [] of String)).value!
        {"2026-08-10", "2026-09-05"}.each do |day|
          Api.propose_reminders(InvoicingSpec.actor, InvoicingSpec.date(day)).each do |reminder|
            Api.send_reminder(InvoicingSpec.actor, reminder.id).value!
          end
        end

        transport.messages.size.should be >= 3
        transport.messages.each do |message|
          untranslated(message.subject + "\n" + message.body).should eq([] of String)
        end
      ensure
        Api.mail_transport = previous
      end
    end
  end
end
