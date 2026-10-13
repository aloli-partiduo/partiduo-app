# SPDX-License-Identifier: AGPL-3.0-or-later

require "base64"
require "socket"
require "openssl"
require "uri"
require "random/secure"

module Partiduo
  module Core
    # Transport des courriels de l'instance (A-REP-2) : un seul pour tout le
    # dossier, partagé par la Facturation (envoi des documents et des
    # relances) et par les extensions (`Partiduo::Api::Mail`). Venu de la
    # Facturation, qui l'avait d'abord pour elle seule (ADR-006 D5) :
    #
    # * `SmtpTransport` — client SMTP minimal (EHLO, STARTTLS ou TLS direct,
    #   AUTH PLAIN, MAIL, RCPT, DATA), configuré par `PARTIDUO_SMTP_URL`
    #   (`smtp://utilisateur:secret@hôte:587?security=starttls`,
    #   `smtps://hôte:465`) ;
    # * `MemoryTransport` — garde les messages en mémoire (specs,
    #   développement) ;
    # * `DisabledTransport` — aucun envoi (défaut sans configuration).
    module Mail
      ADDRESS = /\A[^@\s<>,;"]+@[^@\s<>,;"]+\.[^@\s<>,;"]+\z/

      def self.valid_address?(address : String) : Bool
        address.matches?(ADDRESS)
      end

      class DeliveryError < Exception
      end

      record Attachment, filename : String, content_type : String, content : Bytes

      # Message prêt à partir ; `to_mime` produit le texte RFC 5322 (MIME,
      # UTF-8, pièces jointes en base64, lignes terminées par CRLF).
      class Message
        getter from : String
        getter from_name : String
        getter to : Array(String)
        getter cc : Array(String)
        getter subject : String
        getter body : String
        getter attachments : Array(Attachment)
        getter message_id : String
        getter date : Time
        # Adresse de réponse, si elle diffère de l'expéditeur (A-REP-2 :
        # expéditeur de l'instance, réponses à la société).
        property reply_to : String? = nil

        def initialize(@from : String, @from_name : String, @to : Array(String), @cc : Array(String),
                       @subject : String, @body : String, @attachments = [] of Attachment,
                       @message_id = "<#{Random::Secure.hex(12)}@partiduo>", @date = Time.utc)
        end

        def recipients : Array(String)
          (to + cc).uniq
        end

        def self.encode_header(text : String) : String
          return text if text.ascii_only? && !text.includes?('\n')
          "=?UTF-8?B?#{Base64.strict_encode(text)}?="
        end

        def self.wrap(encoded : String) : String
          encoded.scan(/.{1,76}/).map(&.[0]).join("\r\n")
        end

        def to_mime : String
          boundary = "partiduo-#{Random::Secure.hex(12)}"
          String.build do |io|
            sender = from_name.empty? ? from : "#{Message.encode_header(from_name)} <#{from}>"
            io << "From: " << sender << "\r\n"
            io << "To: " << to.join(", ") << "\r\n"
            io << "Cc: " << cc.join(", ") << "\r\n" unless cc.empty?
            reply_to.try { |address| io << "Reply-To: " << address << "\r\n" }
            io << "Subject: " << Message.encode_header(subject) << "\r\n"
            io << "Date: " << date.to_rfc2822 << "\r\n"
            io << "Message-ID: " << message_id << "\r\n"
            io << "MIME-Version: 1.0\r\n"
            io << "Content-Type: multipart/mixed; boundary=\"" << boundary << "\"\r\n\r\n"
            io << "--" << boundary << "\r\n"
            io << "Content-Type: text/plain; charset=UTF-8\r\n"
            io << "Content-Transfer-Encoding: base64\r\n\r\n"
            io << Message.wrap(Base64.strict_encode(body)) << "\r\n"
            attachments.each do |attachment|
              io << "--" << boundary << "\r\n"
              io << "Content-Type: " << attachment.content_type << "; name=\"" << attachment.filename << "\"\r\n"
              io << "Content-Transfer-Encoding: base64\r\n"
              io << "Content-Disposition: attachment; filename=\"" << attachment.filename << "\"\r\n\r\n"
              io << Message.wrap(Base64.strict_encode(attachment.content)) << "\r\n"
            end
            io << "--" << boundary << "--\r\n"
          end
        end
      end

      abstract class Transport
        # Remet le message ; lève `DeliveryError` en cas de refus.
        abstract def deliver(message : Message) : Nil

        def configured? : Bool
          true
        end
      end

      class DisabledTransport < Transport
        def deliver(message : Message) : Nil
          raise DeliveryError.new("aucun transport de courriel configuré (PARTIDUO_SMTP_URL)")
        end

        def configured? : Bool
          false
        end
      end

      class MemoryTransport < Transport
        getter messages = [] of Message
        property failure : String? = nil

        def deliver(message : Message) : Nil
          if error = failure
            raise DeliveryError.new(error)
          end
          @messages << message
        end

        def clear : Nil
          @messages.clear
        end
      end

      class SmtpTransport < Transport
        enum Security
          None
          StartTls
          Tls
        end

        getter host : String
        getter port : Int32
        getter username : String?
        getter password : String?
        getter security : Security
        getter helo : String
        # Ouverture de la connexion, remplaçable (specs : dialogue simulé).
        property connector : Proc(IO)? = nil
        property timeout : Time::Span = 30.seconds

        def initialize(@host : String, @port : Int32 = 587, @username : String? = nil, @password : String? = nil,
                       @security : Security = Security::StartTls, @helo : String = "partiduo.localhost")
        end

        # `smtp://utilisateur:secret@hôte:587?security=starttls|none` ou
        # `smtps://hôte:465` (TLS direct).
        def self.from_url(url : String) : SmtpTransport
          uri = URI.parse(url)
          host = uri.host.presence || raise ArgumentError.new("URL SMTP sans hôte")
          tls = uri.scheme == "smtps"
          security = if tls
                       Security::Tls
                     else
                       case uri.query_params["security"]?
                       when "none" then Security::None
                       when "tls"  then Security::Tls
                       else             Security::StartTls
                       end
                     end
          helo = uri.query_params["helo"]? || "partiduo.localhost"
          new(host, uri.port || (tls ? 465 : 587), uri.user.try { |user| URI.decode(user) },
            uri.password.try { |secret| URI.decode(secret) }, security, helo)
        end

        def deliver(message : Message) : Nil
          io = open
          begin
            expect(io, [220])
            command(io, "EHLO #{helo}", [250])
            if security.start_tls?
              command(io, "STARTTLS", [220])
              io = upgrade(io)
              command(io, "EHLO #{helo}", [250])
            end
            if (user = username) && (secret = password)
              command(io, "AUTH PLAIN #{Base64.strict_encode("\0#{user}\0#{secret}")}", [235])
            end
            command(io, "MAIL FROM:<#{message.from}>", [250])
            message.recipients.each { |recipient| command(io, "RCPT TO:<#{recipient}>", [250, 251]) }
            command(io, "DATA", [354])
            message.to_mime.split("\r\n").each do |line|
              io << (line.starts_with?('.') ? ".#{line}" : line) << "\r\n"
            end
            io << ".\r\n"
            io.flush
            expect(io, [250])
            begin
              command(io, "QUIT", [221])
            rescue DeliveryError | IO::Error
            end
          ensure
            io.close rescue nil
          end
        end

        private def open : IO
          if connector = @connector
            return connector.call
          end
          socket = TCPSocket.new(host, port, connect_timeout: timeout)
          socket.read_timeout = timeout
          security.tls? ? upgrade(socket) : socket
        end

        private def upgrade(io : IO) : IO
          context = OpenSSL::SSL::Context::Client.new
          OpenSSL::SSL::Socket::Client.new(io, context: context, sync_close: true, hostname: host)
        end

        private def command(io : IO, line : String, codes : Array(Int32)) : String
          io << line << "\r\n"
          io.flush
          expect(io, codes)
        end

        private def expect(io : IO, codes : Array(Int32)) : String
          reply = String.build do |text|
            loop do
              line = io.gets(chomp: true) || raise DeliveryError.new("connexion SMTP fermée")
              text << line << '\n'
              break unless line.size > 3 && line[3] == '-'
            end
          end
          code = reply[0, 3].to_i? || 0
          raise DeliveryError.new("SMTP #{reply.strip}") unless codes.includes?(code)
          reply
        end
      end

      @@transport : Transport? = nil

      # Transport de l'instance : SMTP si `PARTIDUO_SMTP_URL` est donnée,
      # sinon aucun envoi. En specs (`MARTEN_ENV=test`), jamais SMTP : rien
      # ne sort, même si la variable traîne dans l'environnement ; les specs
      # capturent les messages par `MemoryTransport`.
      def self.transport : Transport
        @@transport ||= if (url = ENV["PARTIDUO_SMTP_URL"]?.presence) && ENV["MARTEN_ENV"]? != "test"
                          SmtpTransport.from_url(url)
                        else
                          DisabledTransport.new
                        end
      end

      def self.transport=(transport : Transport?) : Transport?
        @@transport = transport
      end
    end
  end
end
