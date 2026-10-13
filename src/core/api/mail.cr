# SPDX-License-Identifier: AGPL-3.0-or-later

require "digest/sha256"

module Partiduo
  module Api
    # Contrat du socle — envoi de courriels par une extension (A-REP-2) :
    # documents d'un listing, avis, rapports. Le transport est celui de
    # l'instance (`Partiduo::Core::Mail`, `PARTIDUO_SMTP_URL`), partagé avec
    # la Facturation ; l'expéditeur est imposé par le dossier ; le message
    # part *après la validation* de la transaction de l'appelant
    # (`Events.after_commit` : rien ne part d'une opération annulée) et
    # chaque envoi est journalisé (`core_mail_message`). Référence :
    # `doc/api/mail.adoc`.
    module Mail
      # Destinataires (À et Cc) d'un message, au plus.
      MAX_RECIPIENTS =      50
      MAX_SUBJECT    =     255
      MAX_BODY       = 100_000
      # Pièces jointes d'un message, en tout (celle d'une pièce du socle).
      MAX_ATTACHMENT_BYTES = Partiduo::Core::Attachments::MAX_BYTES

      # Pièce jointe donnée par son contenu.
      record AttachmentInput, filename : String, content_type : String, content : Bytes

      # Message : destinataires, copie, sujet, corps (texte), pièces jointes
      # données par leur contenu (`attachments`) ou par une pièce du socle
      # (`attachment_ids`, droit `core.attachment.read`).
      record MessageInput,
        to : Array(String),
        subject : String,
        body : String,
        cc : Array(String) = [] of String,
        attachments : Array(AttachmentInput) = [] of AttachmentInput,
        attachment_ids : Array(Int64) = [] of Int64

      # Message journalisé. `status` : `queued` (part à la validation de la
      # transaction en cours), `sent`, `failed` (`error` : refus du
      # transport) ; `attachments` : noms des pièces jointes.
      record MessageView,
        id : Int64,
        module_code : String,
        sent_by_id : Int64?,
        sender : String,
        reply_to : String,
        to : Array(String),
        cc : Array(String),
        subject : String,
        attachments : Array(String),
        message_id : String,
        status : String,
        error : String,
        created_at : Time,
        sent_at : Time? do
        def sent? : Bool
          status == "sent"
        end

        def failed? : Bool
          status == "failed"
        end
      end

      # Un transport est-il configuré ? Sinon `deliver` refuse
      # (`core.errors.mail.not_configured`) : l'écran n'offre pas l'envoi.
      def self.configured?(actor : Actor) : Bool
        Guard.authorize!(actor, nil)
        Partiduo::Core::Mail.transport.configured?
      end

      # Adresse d'expédition imposée : celle de l'instance
      # (`PARTIDUO_MAIL_FROM`) si elle est donnée, sinon celle de la société ;
      # `nil` s'il n'y en a pas.
      def self.sender(actor : Actor) : String?
        Guard.authorize!(actor, nil)
        sender_address
      end

      # Envoie un message au nom de la pièce `module_code` (active), pour un
      # utilisateur authentifié au niveau exigé ; l'appelant vérifie au
      # préalable son propre droit (« envoyer les documents d'un listing »).
      #
      # Expéditeur : `PARTIDUO_MAIL_FROM` ou l'adresse de la société, nom de
      # la société ; réponses à la société (`Reply-To`) si l'adresse
      # d'expédition est celle de l'instance. Le message est journalisé
      # (`queued`) dans la transaction de l'appel et part à sa validation ;
      # appelé hors transaction, il est déjà parti au retour (`sent` ou
      # `failed`).
      #
      # Refus (`core.errors.mail.*`) : `to.blank`, `to.invalid` (`%{address}`,
      # aussi pour `cc`), `to.too_many` (`%{max}`), `subject.blank`,
      # `subject.too_long`, `body.too_long`, `attachments.too_large`
      # (`%{max}` Mo), `attachments.filename`, `base` : `no_sender`,
      # `not_configured`.
      def self.deliver(actor : Actor, input : MessageInput, module_code : String) : Result(MessageView)
        Guard.authorize!(actor, nil)
        code = module_code.strip.upcase
        Guard.require_module!(code)
        raise Forbidden.new("core.attachment.read") unless input.attachment_ids.empty? || actor.can?("core.attachment.read")
        result = Transaction.run do
          message, errors = compose(input)
          next Result(MessageView).failure(errors) if message.nil?
          row = Partiduo::Core::MailMessage.create!(
            module_code: code, sent_by_id: actor.user_id, sender: message.from, reply_to: message.reply_to || "",
            recipients: message.to.join(","), cc: message.cc.join(","), subject: message.subject, body: message.body,
            attachments: message.attachments.map { |file| "#{file.filename}\t#{Digest::SHA256.hexdigest(file.content)}" }.join('\n'),
            message_id: message.message_id, status: "queued",
          )
          id = row.id!.to_i64
          Partiduo::Events.after_commit { send_now(id, message) }
          Result(MessageView).success(view(row))
        end
        return result if result.failure? || Marten::DB::Connection.default.in_transaction?
        Result(MessageView).success(view(find(result.value!.id)))
      end

      # Un message journalisé : son auteur le lit, ou qui gère le dossier
      # (`core.settings.manage`). `NotFound` sinon.
      def self.message(actor : Actor, id : Int64) : MessageView
        Guard.authorize!(actor, nil)
        row = find(id)
        unless actor.can?("core.settings.manage") || (row.sent_by_id && row.sent_by_id == actor.user_id)
          raise NotFound.new("mail_message", id)
        end
        view(row)
      end

      # Journal des messages, du plus récent au plus ancien, d'une pièce ou
      # de toutes. Droit : `core.settings.manage`.
      def self.messages(actor : Actor, module_code : String? = nil, limit : Int32 = 100, offset : Int32 = 0) : Array(MessageView)
        Guard.authorize!(actor, "core.settings.manage")
        rows = Partiduo::Core::MailMessage.all
        module_code.try { |code| rows = rows.filter(module_code: code.strip.upcase) }
        rows.order("-created_at", "-id")[offset.clamp(0, nil)...(offset.clamp(0, nil) + limit.clamp(1, 500))].to_a.map { |row| view(row) }
      end

      # --- Interne -----------------------------------------------------------

      protected def self.sender_address : String?
        ENV["PARTIDUO_MAIL_FROM"]?.try(&.strip).presence ||
          Partiduo::Core::SettingsRules.current.try(&.email.to_s.strip).presence
      end

      # Message prêt à partir, ou ses erreurs.
      private def self.compose(input : MessageInput) : {Partiduo::Core::Mail::Message?, Array(FieldError)}
        errors = [] of FieldError
        to = clean(input.to)
        cc = clean(input.cc)
        address_errors(to, cc, errors)
        subject = input.subject.gsub(/[[:cntrl:]]/, " ").strip
        text_errors(subject, input.body, errors)
        files = attachments(input, errors)
        settings = Partiduo::Core::SettingsRules.current
        from = sender_address
        errors << FieldError.base("core.errors.mail.no_sender") if from.nil?
        errors << FieldError.base("core.errors.mail.not_configured") unless Partiduo::Core::Mail.transport.configured?
        return {nil, errors} unless errors.empty? && from

        company = settings.try(&.company_name.to_s) || ""
        message = Partiduo::Core::Mail::Message.new(from, company, to, cc, subject, input.body, files)
        company_email = settings.try(&.email.to_s.strip).presence
        message.reply_to = company_email if company_email && company_email != from
        {message, errors}
      end

      private def self.address_errors(to : Array(String), cc : Array(String), errors : Array(FieldError)) : Nil
        errors << error("to", "to.blank") if to.empty?
        (to + cc).each do |address|
          next if Partiduo::Core::Mail.valid_address?(address)
          errors << error(to.includes?(address) ? "to" : "cc", "to.invalid", {"address" => address})
        end
        errors << error("to", "to.too_many", {"max" => MAX_RECIPIENTS.to_s}) if (to + cc).uniq!.size > MAX_RECIPIENTS
      end

      private def self.text_errors(subject : String, body : String, errors : Array(FieldError)) : Nil
        if subject.empty?
          errors << error("subject", "subject.blank")
        elsif subject.size > MAX_SUBJECT
          errors << error("subject", "subject.too_long", {"max" => MAX_SUBJECT.to_s})
        end
        errors << error("body", "body.too_long", {"max" => MAX_BODY.to_s}) if body.size > MAX_BODY
      end

      private def self.attachments(input : MessageInput, errors : Array(FieldError)) : Array(Partiduo::Core::Mail::Attachment)
        files = input.attachments.map do |file|
          name = Partiduo::Core::Attachments.clean_filename(file.filename).gsub(/["\\\\]/, "_")
          errors << error("attachments", "attachments.filename") if name.empty?
          Partiduo::Core::Mail::Attachment.new(name, file.content_type.split(';').first.strip.presence || "application/octet-stream",
            file.content)
        end
        input.attachment_ids.each do |id|
          stored = Core.attachment(Actor.system, id)
          files << Partiduo::Core::Mail::Attachment.new(stored.filename.gsub(/["\\\\]/, "_"), stored.content_type,
            Core.attachment_content(Actor.system, id))
        end
        if files.sum(0_i64, &.content.size.to_i64) > MAX_ATTACHMENT_BYTES
          errors << error("attachments", "attachments.too_large", {"max" => (MAX_ATTACHMENT_BYTES // (1024 * 1024)).to_s})
        end
        files
      end

      private def self.clean(addresses : Array(String)) : Array(String)
        addresses.flat_map(&.split(/[,;]/)).map(&.strip).reject(&.empty?).uniq!
      end

      # Envoi après validation : l'état du journal suit le transport, sans
      # transaction (rien à annuler si le transport refuse).
      private def self.send_now(id : Int64, message : Partiduo::Core::Mail::Message) : Nil
        error = nil
        begin
          Partiduo::Core::Mail.transport.deliver(message)
        rescue ex : Partiduo::Core::Mail::DeliveryError | IO::Error | Socket::Error | OpenSSL::Error
          error = ex.message || ex.class.name
        end
        Partiduo::Core::MailMessage.filter(id: id).update(status: error ? "failed" : "sent", error: error || "",
          sent_at: error ? nil : Time.utc)
      end

      private def self.find(id : Int64) : Partiduo::Core::MailMessage
        Partiduo::Core::MailMessage.filter(id: id).first || raise NotFound.new("mail_message", id)
      end

      private def self.view(row : Partiduo::Core::MailMessage) : MessageView
        MessageView.new(
          id: row.id!.to_i64, module_code: row.module_code!, sent_by_id: row.sent_by_id.try(&.to_i64),
          sender: row.sender!, reply_to: row.reply_to.to_s, to: row.recipients!.split(',').reject(&.empty?),
          cc: row.cc.to_s.split(',').reject(&.empty?), subject: row.subject!,
          attachments: row.attachments.to_s.split('\n').reject(&.empty?).map(&.split('\t').first),
          message_id: row.message_id!, status: row.status!, error: row.error.to_s, created_at: row.created_at!,
          sent_at: row.sent_at,
        )
      end

      private def self.error(field : String, key : String, params = {} of String => String) : FieldError
        FieldError.new(field, "core.errors.mail.#{key}", params)
      end
    end
  end
end
