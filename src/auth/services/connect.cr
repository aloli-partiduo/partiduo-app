# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"
require "log"
require "uri"

module Partiduo
  module Auth
    # connect, fournisseur d'identité commun aux dossiers (ADR-012) : un
    # fournisseur OpenID Connect comme les autres pour la fédération
    # (`OidcAdapter`), mais réglé par l'environnement de l'instance, posé à
    # la création du dossier, et non par l'écran des fournisseurs :
    #
    # * `PARTIDUO_CONNECT_URL` : émetteur (`https://connect.<domaine>`) ;
    # * `PARTIDUO_CONNECT_CLIENT_ID`, `PARTIDUO_CONNECT_CLIENT_SECRET` (ou
    #   `PARTIDUO_CONNECT_CLIENT_SECRET_FILE`) : le client de ce dossier.
    #
    # Les adresses de connect se déduisent de l'émetteur ; celles du dossier,
    # de son nom d'hôte. Une fois réglé, connect est la connexion des
    # utilisateurs ; le mot de passe local et la passkey locale ne restent
    # qu'aux administrateurs de la société, en secours (ADR-012 D5).
    module Connect
      CODE = "connect"
      NAME = "Partiduo"

      Log = ::Log.for("partiduo.connect")

      def self.url : String?
        ENV["PARTIDUO_CONNECT_URL"]?.presence.try(&.rchop('/'))
      end

      def self.client_id : String?
        ENV["PARTIDUO_CONNECT_CLIENT_ID"]?.presence
      end

      def self.client_secret : String?
        if path = ENV["PARTIDUO_CONNECT_CLIENT_SECRET_FILE"]?.presence
          return File.read(path).strip.presence if File::Info.readable?(path)
        end
        ENV["PARTIDUO_CONNECT_CLIENT_SECRET"]?.presence
      end

      def self.configured? : Bool
        !url.nil? && !client_id.nil? && !client_secret.nil?
      end

      # Adresse publique du dossier : https, sauf `*.localhost` (http, port
      # de l'instance).
      def self.base_url(host : String) : String
        return "http://#{host}:#{ENV["PORT"]? || "8000"}" if host.ends_with?(".localhost")
        "https://#{host}"
      end

      # Nom d'hôte du dossier (`<dossier>.<domaine>`, réglages de la société),
      # à défaut le domaine de l'instance.
      def self.instance_host : String
        Partiduo::Api::Core.settings(Partiduo::Api::Actor.system).domain.presence || Partiduo::Config.domain
      rescue Partiduo::Api::NotFound
        Partiduo::Config.domain
      end

      def self.callback_path : String
        "/login/federated/#{CODE}/callback"
      end

      def self.backchannel_path : String
        "/login/federated/#{CODE}/backchannel-logout"
      end

      # Paramètres du client (forme de ceux d'un fournisseur `oidc`).
      def self.settings(host : String) : Hash(String, String)
        issuer = url || ""
        {
          "issuer"                 => issuer,
          "authorization_endpoint" => "#{issuer}/authorize",
          "token_endpoint"         => "#{issuer}/token",
          "jwks_uri"               => "#{issuer}/jwks.json",
          "client_id"              => client_id || "",
          "client_secret"          => client_secret || "",
          "redirect_uri"           => "#{base_url(host)}#{callback_path}",
          "scopes"                 => "openid email profile",
        }
      end

      # Fournisseur `connect` de l'instance, créé à la première demande
      # quand connect est réglé (niveau 3 : le plafond ; le niveau d'une
      # connexion est celui qu'atteste connect, `acr`). `nil` sinon.
      def self.provider : IdentityProvider?
        return unless configured?
        existing = IdentityProvider.filter(code: CODE).first
        return existing if existing
        IdentityProvider.create!(code: CODE, kind: "oidc", name: NAME, level: Levels::PASSKEY, active: true, settings: "{}")
      rescue Marten::DB::Errors::InvalidRecord
        IdentityProvider.filter(code: CODE).first
      end

      def self.provider?(provider : IdentityProvider) : Bool
        provider.code == CODE
      end

      # Déconnexion chez connect (point `end_session_endpoint`) : ferme la
      # session commune et celles des autres dossiers (ADR-012 D8), puis
      # revient à la page de connexion du dossier.
      def self.end_session_url(host : String) : String?
        issuer = url || return
        params = URI::Params.encode({"client_id" => client_id || "", "post_logout_redirect_uri" => "#{base_url(host)}/login"})
        "#{issuer}/logout?#{params}"
      end

      # Invitation à créer un compte connect (ADR-012 D6) : `{url, code}`, ou
      # `nil` si la personne a déjà un compte ou si connect ne répond pas
      # (l'invitation locale reste valable ; elle mène alors à la connexion).
      record Ticket, url : String, code : String

      record TicketOutcome, ticket : Ticket? = nil, account : Bool = false

      def self.signup_ticket(email : String, name : String, locale : String, return_to : String) : TicketOutcome
        issuer = url
        return TicketOutcome.new if issuer.nil? || !configured?
        status, body = OidcAdapter.transport.post_form("#{issuer}/api/v1/signup-tickets", {
          "client_id"     => client_id || "",
          "client_secret" => client_secret || "",
          "email"         => email,
          "name"          => name,
          "locale"        => locale,
          "return_to"     => return_to,
        })
        unless status == 200
          Log.warn { "Invitation connect refusée pour #{email} : HTTP #{status} #{body[0, 200]?}" }
          return TicketOutcome.new
        end
        json = JSON.parse(body)
        return TicketOutcome.new(account: true) if json["account"]?.try(&.as_bool?)
        ticket_url = json["url"]?.try(&.as_s?)
        code = json["code"]?.try(&.as_s?)
        return TicketOutcome.new if ticket_url.nil? || code.nil?
        TicketOutcome.new(ticket: Ticket.new(ticket_url, code))
      rescue ex : Federation::Error | JSON::ParseException
        Log.warn { "Invitation connect impossible pour #{email} : #{ex.message}" }
        TicketOutcome.new
      end
    end
  end
end
