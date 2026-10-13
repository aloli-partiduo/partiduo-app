# SPDX-License-Identifier: AGPL-3.0-or-later

require "base64"
require "socket"
require "openssl"
require "uri"
require "random/secure"

module Partiduo
  module Invoicing
    # Envoi des documents et des relances par courriel (ADR-006 D5), tracé
    # sur le document (`EmailLog`). Le transport est celui du socle
    # (`Partiduo::Core::Mail`, A-REP-2), configurable par l'instance.
    module Mail
      # Transport et messages du socle (`Partiduo::Core::Mail`, A-REP-2) :
      # les noms d'origine restent valables.
      ADDRESS = Partiduo::Core::Mail::ADDRESS

      alias DeliveryError = Partiduo::Core::Mail::DeliveryError
      alias Attachment = Partiduo::Core::Mail::Attachment
      alias Message = Partiduo::Core::Mail::Message
      alias Transport = Partiduo::Core::Mail::Transport
      alias DisabledTransport = Partiduo::Core::Mail::DisabledTransport
      alias MemoryTransport = Partiduo::Core::Mail::MemoryTransport
      alias SmtpTransport = Partiduo::Core::Mail::SmtpTransport

      def self.valid_address?(address : String) : Bool
        Partiduo::Core::Mail.valid_address?(address)
      end

      def self.transport : Transport
        Partiduo::Core::Mail.transport
      end

      def self.transport=(transport : Transport?) : Transport?
        Partiduo::Core::Mail.transport = transport
      end

      # Message d'envoi d'un document émis : destinataires (par défaut
      # l'adresse du client), expéditeur des paramètres (sinon celle de la
      # société), textes par défaut dans la langue du document, PDF joint.
      def self.compose(view : Partiduo::Api::Invoicing::DocumentView, input : Partiduo::Api::Invoicing::SendInput,
                       & : -> Partiduo::Api::Invoicing::FileView) : {Message?, Array(Partiduo::Api::FieldError)}
        errors = [] of Partiduo::Api::FieldError
        recipients = input.to.map(&.strip).reject(&.empty?)
        recipients = [view.customer.email] if recipients.empty? && !view.customer.email.empty?
        cc = input.cc.map(&.strip).reject(&.empty?)
        if recipients.empty?
          errors << Documents.error("to", "mail.no_recipient")
        elsif (recipients + cc).any? { |address| !valid_address?(address) }
          errors << Documents.error("to", "mail.invalid_address")
        end
        settings = Configuration.settings
        sender = settings.sender_email.presence || view.seller.email
        errors << Documents.error(Partiduo::Api::FieldError::BASE, "mail.no_sender") if sender.empty?
        errors << Documents.error(Partiduo::Api::FieldError::BASE, "mail.not_configured") unless transport.configured?
        return {nil, errors} unless errors.empty?

        params = {"kind" => I18n.with_locale(view.locale) { I18n.t(view.kind_key) }, "number" => view.number.to_s,
                  "seller" => view.seller.name, "customer" => view.customer.name,
                  "amount" => Output.format_amount(view.totals.payable, view.locale, view.currency_code),
                  "due_date" => Output.format_date(view.due_date, view.locale)}
        subject, body = I18n.with_locale(view.locale) do
          {input.subject || I18n.t("invoicing.mail.subject", params), input.body || I18n.t("invoicing.mail.body", params)}
        end
        pdf = yield
        message = Message.new(sender, settings.sender_name.presence || view.seller.name, recipients, cc, subject, body,
          [Attachment.new(pdf.filename, pdf.content_type, pdf.content)])
        {message, errors}
      end

      # Envoie, trace l'envoi (réussi ou non) et, s'il a réussi, marque le
      # document envoyé (une facture passe à l'état « envoyée »).
      def self.send_and_record(message : Message, document_id : Int64, reminder_id : Int64?,
                               actor : Partiduo::Api::Actor) : Partiduo::Api::Invoicing::EmailLogView
        log, error = deliver_and_log(message, document_id, reminder_id, actor)
        if error
          Documents.log(document_id, "email_failed", actor, "", {"error" => error})
        else
          document = Documents.find(document_id, lock: true)
          document.sent_at = Time.utc
          if Payments::PAYABLE_KINDS.includes?(document.kind)
            Payments.refresh_status(document)
          else
            document.save!
          end
          Documents.log(document_id, "emailed", actor, "", {"to" => message.recipients.join(", ")})
        end
        log_view(log)
      end

      # Envoie le message et en garde la trace sur le document ; un échec de
      # transport est tracé aussi (statut `failed`) puis signalé.
      def self.deliver_and_log(message : Message, document_id : Int64, reminder_id : Int64?,
                               actor : Partiduo::Api::Actor) : {EmailLog, String?}
        error = nil
        begin
          transport.deliver(message)
        rescue ex : DeliveryError | IO::Error | Socket::Error | OpenSSL::Error
          error = ex.message || ex.class.name
        end
        attachment = message.attachments.first?
        log = EmailLog.create!(
          document_id: document_id, reminder_id: reminder_id, recipients: message.recipients.join(", "),
          subject: message.subject[0, Math.min(255, message.subject.size)], body: message.body,
          attachment_name: attachment.try(&.filename) || "",
          attachment_sha256: attachment.try { |file| Digest::SHA256.hexdigest(file.content) } || "",
          message_id: message.message_id, status: error ? "failed" : "sent", error: error || "",
          sent_by_id: actor.user_id,
        )
        {log, error}
      end

      def self.log_view(log : EmailLog) : Partiduo::Api::Invoicing::EmailLogView
        Partiduo::Api::Invoicing::EmailLogView.new(
          id: Documents.id_of(log.id), document_id: Documents.id_of(log.document_id),
          reminder_id: log.reminder_id.try { |reminder_id| Documents.id_of(reminder_id) },
          recipients: log.recipients!.split(", "), subject: log.subject!, attachment_name: log.attachment_name.to_s,
          attachment_sha256: log.attachment_sha256.to_s, message_id: log.message_id.to_s, status: log.status!,
          error: log.error.to_s, sent_by_id: log.sent_by_id.try(&.to_i64), created_at: log.created_at!,
        )
      end
    end
  end
end
