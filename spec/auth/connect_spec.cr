# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# connect, identité commune aux dossiers (ADR-012) : le dossier est un
# client OpenID Connect ; l'autorisation reste locale.

private alias Auth = Partiduo::Api::Auth

private def link(user_id : Int64, subject : String = "sub-connect")
  Partiduo::Auth::FederatedIdentity.create!(user: Partiduo::Auth::User.get!(id: user_id),
    provider: Partiduo::Auth::Connect::CODE, subject: subject)
end

describe "connect (ADR-012), côté dossier" do
  it "vérifie un jeton ES256 et prend le niveau attesté par connect (acr), plafonné à 3" do
    ConnectSpec.with_connect do |transport|
      created = AuthSpec.create_user("alice@example.com", profile: nil)
      link(created.user.id)
      view = ConnectSpec.login(transport, acr: "3").value!
      view.user_id.should eq(created.user.id)
      view.level.should eq(3)
      ConnectSpec.login(transport, acr: "2").value!.level.should eq(2)
      Partiduo::Auth::Session.filter(user_id: created.user.id, federated_sid: "sid-1").count.should eq(2)
    end
  end

  it "prend la langue du compte connect à chaque connexion, et rien sans claim (D-UI-082)" do
    ConnectSpec.with_connect do |transport|
      created = AuthSpec.create_user("alice@example.com", profile: nil)
      link(created.user.id)
      session_of = ->(view : Auth::LoginView) { Auth.session(view.session_token!) || raise "session absente" }

      german = session_of.call(ConnectSpec.login(transport, locale: "de-DE").value!)
      {german.locale, german.locale_from_connect}.should eq({"de", true})
      Partiduo::Auth::User.get!(id: created.user.id).locale.should eq("de")

      # Changement fait dans connect : repris à la connexion suivante.
      session_of.call(ConnectSpec.login(transport, locale: "it").value!).locale.should eq("it")

      # Compte connect sans langue, ou langue non livrée : le navigateur décide.
      [nil, "ja"].each do |claim|
        none = session_of.call(ConnectSpec.login(transport, locale: claim).value!)
        {claim, none.locale, none.locale_from_connect}.should eq({claim, "", true})
      end
      Partiduo::Auth::User.get!(id: created.user.id).locale.should eq("it")
    end
  end

  it "garde la langue de l'utilisateur du dossier pour une session ouverte sans connect" do
    created = AuthSpec.create_user("bob@example.com")
    view = Auth.session(AuthSpec.login("bob@example.com").value!.session_token!) || raise "session absente"
    {view.locale, view.locale_from_connect}.should eq({created.user.locale, false})
  end

  it "demande le niveau et la ré-authentification à connect" do
    ConnectSpec.with_connect do
      start = Auth.begin_federated_login(Partiduo::Api::Actor.anonymous, "connect",
        Auth::FederatedOptions.new(acr: 3, fresh: true, login_hint: "alice@example.com"))
      query = URI.parse(start.redirect_url).query_params
      start.redirect_url.should start_with("#{ConnectSpec::URL}/authorize?")
      {query["acr_values"], query["prompt"], query["login_hint"]}.should eq({"3", "login", "alice@example.com"})
    end
  end

  it "ferme les sessions ouvertes par une session connect à sa déconnexion par canal arrière (D8)" do
    ConnectSpec.with_connect do |transport|
      created = AuthSpec.create_user("alice@example.com", profile: nil)
      link(created.user.id)
      token = ConnectSpec.login(transport).value!.session_token!
      Auth.federated_backchannel_logout("connect", ConnectSpec.logout_token(audience: "autre")).should be_nil
      Auth.session(token).should_not be_nil
      Auth.federated_backchannel_logout("connect", ConnectSpec.logout_token).should eq(1)
      Auth.session(token).should be_nil
    end
  end

  it "lie le compte connect à l'invité si l'adresse vérifiée est la sienne, une seule fois (D6)" do
    ConnectSpec.with_connect do |transport|
      created = AuthSpec.create_user("invite@example.com", password: nil, profile: nil)
      invitation = created.invitation
      invitation.signup_code.should eq("ABCD-EFGH")
      ticket = transport.forms.find! { |(url, _)| url.ends_with?("/api/v1/signup-tickets") }[1]
      ticket["email"].should eq("invite@example.com")
      ticket["return_to"].should end_with("/invitation/#{invitation.token}/connect")
      Auth.invitation_view(Partiduo::Api::Actor.anonymous, invitation.token).try(&.signup_url)
        .should eq("#{ConnectSpec::URL}/signup/jeton-connect")

      # Un autre compte connect (courriel intercepté) : refusé, invitation intacte.
      ConnectSpec.login(transport, invitation: invitation.token, subject: "pirate", email: "pirate@example.net")
        .error_keys.should eq(["auth.errors.federated.invitation_email"])

      view = ConnectSpec.login(transport, invitation: invitation.token, email: "invite@example.com").value!
      view.user_id.should eq(created.user.id)
      Partiduo::Auth::FederatedIdentity.filter(user_id: created.user.id, provider: "connect").count.should eq(1)
      Auth.invitation_view(Partiduo::Api::Actor.anonymous, invitation.token).should be_nil
    end
  end

  it "ne réserve la connexion locale qu'aux administrateurs de la société, en secours (D5)" do
    AuthSpec.create_user("membre@example.com", profile: nil)
    AuthSpec.create_user("admin@example.com")
    ConnectSpec.with_connect do
      AuthSpec.login("membre@example.com").error_keys.should eq(["auth.errors.login.use_connect"])
      AuthSpec.login("admin@example.com").success?.should be_true
    end
    AuthSpec.login("membre@example.com").success?.should be_true
  end

  it "reporte l'adresse changée chez connect sur le compte local (D8)" do
    ConnectSpec.with_connect do |transport|
      created = AuthSpec.create_user("ancienne@example.com", profile: nil)
      link(created.user.id)
      ConnectSpec.login(transport, email: "nouvelle@example.com").success?.should be_true
      Partiduo::Auth::User.get!(id: created.user.id).email.should eq("nouvelle@example.com")
    end
  end

  it "propose connect en premier parmi les fournisseurs, et la déconnexion chez connect" do
    ConnectSpec.with_connect do |transport|
      Auth.login_providers(Partiduo::Api::Actor.anonymous).first.code.should eq("connect")
      created = AuthSpec.create_user("alice@example.com", profile: nil)
      link(created.user.id)
      token = ConnectSpec.login(transport).value!.session_token!
      url = Auth.federated_logout_url(token, "demo.partiduo.example") || ""
      url.should start_with("#{ConnectSpec::URL}/logout?client_id=demo")
      url.should contain(URI.encode_www_form("https://demo.partiduo.example/login"))
      AuthSpec.create_user("chef@example.com")
      Auth.federated_logout_url(AuthSpec.session_token("chef@example.com"), "x").should be_nil
    end
  end
end
