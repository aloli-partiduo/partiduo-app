# SPDX-License-Identifier: AGPL-3.0-or-later

require "jose"

# connect simulé (ADR-012) : environnement de l'instance réglé le temps d'un
# exemple, transport HTTP remplacé, clé ES256, jetons forgés à la demande.
module ConnectSpec
  URL       = "https://connect.partiduo.localhost"
  CLIENT_ID = "demo"
  SECRET    = "secret-du-dossier"

  KEY = Jose::JWK::ECKey.generate(Jose::JWK::Curve::P256)

  class Transport < Partiduo::Auth::OidcAdapter::Transport
    getter forms = [] of {String, Hash(String, String)}
    property id_token = ""
    property ticket = {"account" => false, "url" => "#{URL}/signup/jeton-connect", "code" => "ABCD-EFGH"}.to_json

    def post_form(url : String, form : Hash(String, String)) : {Int32, String}
      forms << {url, form}
      return {200, ticket} if url.ends_with?("/api/v1/signup-tickets")
      {200, {"access_token" => "a", "token_type" => "Bearer", "id_token" => id_token}.to_json}
    end

    def get(url : String) : {Int32, String}
      public = ConnectSpec::KEY.public_key.to_jwk_hash
      public["kid"] = "c1"
      {200, {"keys" => [public]}.to_json}
    end
  end

  # Règle connect pour le bloc, puis remet l'environnement et le transport.
  def self.with_connect(&)
    previous = Partiduo::Auth::OidcAdapter.transport
    transport = Transport.new
    Partiduo::Auth::OidcAdapter.transport = transport
    ENV["PARTIDUO_CONNECT_URL"] = URL
    ENV["PARTIDUO_CONNECT_CLIENT_ID"] = CLIENT_ID
    ENV["PARTIDUO_CONNECT_CLIENT_SECRET"] = SECRET
    begin
      yield transport
    ensure
      %w[PARTIDUO_CONNECT_URL PARTIDUO_CONNECT_CLIENT_ID PARTIDUO_CONNECT_CLIENT_SECRET].each { |name| ENV.delete(name) }
      Partiduo::Auth::OidcAdapter.transport = previous
    end
  end

  def self.sign(claims : Hash(String, JSON::Any), typ : String = "JWT") : String
    Jose::JWS.sign(claims.to_json, Jose::JWS::Algorithm::ES256, KEY, {"kid" => "c1", "typ" => typ})
  end

  def self.id_token(nonce : String, subject : String = "sub-connect", email : String = "alice@example.com",
                    acr : String = "2", sid : String = "sid-1") : String
    sign({
      "iss" => JSON::Any.new(URL), "aud" => JSON::Any.new(CLIENT_ID), "sub" => JSON::Any.new(subject),
      "nonce" => JSON::Any.new(nonce), "exp" => JSON::Any.new((Time.utc + 5.minutes).to_unix),
      "iat" => JSON::Any.new(Time.utc.to_unix), "email" => JSON::Any.new(email), "acr" => JSON::Any.new(acr),
      "sid" => JSON::Any.new(sid), "amr" => JSON::Any.new([JSON::Any.new("pwd"), JSON::Any.new("otp")]),
    })
  end

  def self.logout_token(subject : String = "sub-connect", sid : String = "sid-1", audience : String = CLIENT_ID) : String
    sign({
      "iss" => JSON::Any.new(URL), "aud" => JSON::Any.new(audience), "sub" => JSON::Any.new(subject),
      "sid" => JSON::Any.new(sid), "iat" => JSON::Any.new(Time.utc.to_unix), "jti" => JSON::Any.new("j1"),
      "events" => JSON::Any.new({"http://schemas.openid.net/event/backchannel-logout" => JSON::Any.new({} of String => JSON::Any)}),
    }, typ: "logout+jwt")
  end

  # Connexion complète par connect : rend le résultat du retour.
  def self.login(transport : Transport, invitation : String? = nil, **token) : Partiduo::Api::Result(Partiduo::Api::Auth::LoginView)
    actor = Partiduo::Api::Actor.anonymous
    start = Partiduo::Api::Auth.begin_federated_login(actor, Partiduo::Auth::Connect::CODE)
    query = URI.parse(start.redirect_url).query_params
    transport.id_token = id_token(**token.merge(nonce: query["nonce"]))
    Partiduo::Api::Auth.login_federated(actor, Partiduo::Auth::Connect::CODE, start.request_id,
      {"code" => "code-1", "state" => query["state"]}, invitation_token: invitation)
  end
end
