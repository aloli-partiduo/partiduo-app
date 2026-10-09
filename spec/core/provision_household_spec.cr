# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Dossier de type foyer (ADR-011 A3, DECISIONS D-FOY-003 à D-FOY-005) : type
# choisi au provisionnement, plan comptable réduit à la place du PCG ou du
# PCMN, modules d'entreprise refusés, chargeurs limités à un type, type
# déclaré par une extension, `manage provision --kind` et `manage instance
# status`.

private def system : Partiduo::Api::Actor
  Partiduo::Api::Actor.system
end

private def household_settings(**overrides) : Partiduo::Api::Core::SettingsInput
  settings_input(company_name: "Foyer Martin", legal_form: nil, share_capital: nil, rcs: nil, siren: nil,
    vat_number: nil, domain: "martin.partiduo.localhost").copy_with(**overrides)
end

private def provision_household(settings = household_settings, modules = ["accounting"]) : Partiduo::Api::Result(Partiduo::Api::Core::ProvisionView)
  Partiduo::Api::Core.provision(system, Partiduo::Api::Core::ProvisionInput.new(
    settings: settings, modules: modules, kind: "household"))
end

private def run_command(command_class, *options : String) : {Int32, String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  command = command_class.new(options.to_a, stdout: stdout, stderr: stderr, exit_raises: true)
  {command.handle, stdout.to_s, stderr.to_s}
end

describe "Types de dossier (ADR-011 A3)" do
  it "connaît l'entreprise et le foyer, déclarés par le cœur" do
    company = Partiduo::Api::InitialData.kind?("company") || fail "type company absent"
    company.chart.should eq("company")
    household = Partiduo::Api::InitialData.kind?("household") || fail "type household absent"
    household.chart.should eq("household")
    household.required.should eq(%w[ACCOUNTING])
    household.excluded.should contain("INVOICING")
    Partiduo::Api::InitialData.kinds.map(&.code).should contain("household")
  end

  it "refuse un type mal formé, déclaré deux fois ou de plan inconnu" do
    expect_raises(ArgumentError, /type de dossier invalide/) { Partiduo::Api::InitialData.register_kind("Foyer", "CORE") }
    expect_raises(ArgumentError, /déjà déclaré : household/) { Partiduo::Api::InitialData.register_kind("household", "CORE") }
    expect_raises(ArgumentError, /plan de base inconnu/) do
      Partiduo::Api::InitialData.register_kind("association", "CORE", chart: "asso")
    end
  end
end

describe_module "ACCOUNTING", "Provisionnement d'un dossier foyer (ADR-011 A3)" do
  it "charge le plan réduit français à la place du PCG, sans TVA, et retient le type" do
    with_active_modules("accounting") do
      view = provision_household.value!
      view.settings.kind.should eq("household")
      view.settings.household?.should be_true
      Partiduo::Api::Core.settings(system).kind.should eq("household")
      view.loaders.should contain("ACCOUNTING.reference_data")

      chart = Partiduo::Api::Accounting.chart(system).map(&.account)
      numbers = chart.map(&.number)
      numbers.size.should be < 100
      %w[512001 53 58 2711 2712 213 164 6101 62 6901 701 703].each { |number| numbers.should contain(number) }
      numbers.should_not contain("410")   # pas de clients
      numbers.should_not contain("44571") # pas de TVA
      chart.find!(&.number.==("6101")).label.should eq("Loyer ou échéance")
      chart.find!(&.number.==("2711")).label.should eq("Assurance-vie")

      Partiduo::Api::Accounting.ledgers(system).map(&.code).should eq(%w[F01 O01])
      Partiduo::Api::Accounting.default_account(system, "bank_fees").try(&.number).should eq("604")
      Partiduo::Api::Accounting.default_account(system, "internal_transfer").try(&.number).should eq("58")
      Partiduo::Api::Accounting.default_account(system, "customer").should be_nil
      # Les taux de TVA du socle restent présents et inutilisés (ADR-011 D2).
      Partiduo::Api::Vat.rates(system, include_disabled: true).should_not be_empty
    end
  end

  it "charge le plan réduit belge, libellés dans la langue du dossier" do
    with_active_modules("accounting") do
      settings = household_settings(tax_regime: "be", postcode: "1000", city: "Bruxelles", default_locale: "nl")
      provision_household(settings).value!.settings.kind.should eq("household")
      chart = Partiduo::Api::Accounting.chart(system).map(&.account)
      chart.find!(&.number.==("5501")).label.should eq("Zichtrekening")
      chart.find!(&.number.==("173")).label.should eq("Hypothecaire leningen")
      chart.map(&.number).should_not contain("2712") # pas de PEA en Belgique
      Partiduo::Api::Accounting.default_account(system, "bank").try(&.number).should eq("550")
    end
  end

  it "refuse un module d'entreprise actif et exige la Comptabilité, sans rien écrire" do
    with_active_modules("accounting,invoicing") do
      result = provision_household(modules: %w[accounting invoicing])
      result.errors_for("kind").map(&.key).should eq(["core.errors.provision.kind.excluded"])
      result.errors_for("kind").first.params.should eq({"kind" => "household", "code" => "INVOICING"})
      Partiduo::Core::Settings.all.count.should eq(0)
    end
    with_active_modules("none") do
      result = provision_household(modules: [] of String)
      result.errors_for("kind").map(&.key).should eq(["core.errors.provision.kind.required"])
    end
  end

  it "refuse un type inconnu" do
    with_active_modules("accounting") do
      result = Partiduo::Api::Core.provision(system, Partiduo::Api::Core::ProvisionInput.new(
        settings: household_settings, modules: ["accounting"], kind: "chateau"))
      result.errors_for("kind").map(&.key).should eq(["core.errors.provision.kind.unknown"])
      result.errors_for("kind").first.params["kinds"].should contain("household")
    end
  end

  it "garde le PCG pour un dossier d'entreprise (type par défaut)" do
    view = provision_instance
    view.settings.kind.should eq("company")
    Partiduo::Api::Accounting.chart(system).size.should eq(170)
  end

  it "refuse un plan de base inconnu par le contrat de la Comptabilité" do
    result = Partiduo::Api::Accounting.load_initial_data(system, "fr", "fr", chart: "asso")
    result.failure?.should be_true
  end
end

describe_module "ACCOUNTING", "Accroche des données initiales par type de dossier (ADR-011 A3)" do
  it "n'exécute un chargeur limité à un type que pour ce type ; une extension peut déclarer le sien" do
    calls = [] of String
    Partiduo::Api::InitialData.register("CORE", "spec_household", order: 90, kinds: ["household"]) do |context|
      calls << "household:#{context.kind}:#{context.chart}"
    end
    Partiduo::Api::InitialData.register_kind("spec_kind", "CORE", chart: "household", required: %w[ACCOUNTING])
    Partiduo::Api::InitialData.register("CORE", "spec_kind", order: 91, kinds: ["spec_kind"]) do |context|
      Partiduo::Api::Accounting.create_account(context.actor, Partiduo::Api::Accounting::AccountInput.new(
        number: "6999", label: "Catégorie de l'extension", parent: "6", direct_use: true)).value!
      calls << "spec_kind:#{context.kind}:#{context.chart}"
    end
    begin
      Partiduo::Api::InitialData.loaders("company").map(&.id).should_not contain("CORE.spec_household")
      Partiduo::Api::InitialData.loaders("household").map(&.id).should contain("CORE.spec_household")
      with_active_modules("accounting") do
        view = Partiduo::Api::Core.provision(system, Partiduo::Api::Core::ProvisionInput.new(
          settings: household_settings, modules: ["accounting"], kind: "spec_kind")).value!
        view.settings.kind.should eq("spec_kind")
        view.loaders.should contain("CORE.spec_kind")
        view.loaders.should_not contain("CORE.spec_household")
        calls.should eq(["spec_kind:spec_kind:household"])
        Partiduo::Api::Accounting.account(system, "6999").label.should eq("Catégorie de l'extension")
        Partiduo::Api::Accounting.account(system, "6101").label.should eq("Loyer ou échéance")
      end
    ensure
      Partiduo::Api::InitialData.unregister("CORE", "spec_household")
      Partiduo::Api::InitialData.unregister("CORE", "spec_kind")
      Partiduo::Api::InitialData.unregister_kind("spec_kind")
    end
  end
end

describe_module "ACCOUNTING", "Commandes : manage provision --kind et manage instance status (ADR-011 A3)" do
  it "provisionne un foyer par la commande et le rend dans l'état de l'instance" do
    with_active_modules("accounting") do
      code, output, errors = run_command(Partiduo::Core::Commands::Provision, "--name=Foyer Martin", "--regime=fr",
        "--kind=household", "--modules=accounting", "--domain=martin.partiduo.localhost")
      errors.should eq("")
      code.should eq(0)
      output.should contain("Type de dossier : household.")
      Partiduo::Api::Core.settings(system).kind.should eq("household")

      code, output, _ = run_command(Partiduo::Core::Commands::Instance, "status")
      code.should eq(0)
      json = JSON.parse(output)
      json["contract"].should eq(Partiduo::INSTANCE_CLI_VERSION)
      json["data"]["kind"].should eq("household")
      json["data"]["modules"].as_a.first["incompatible_with"].as_a.should be_empty
    end
  end

  it "refuse par la commande un module d'entreprise dans un foyer" do
    with_active_modules("accounting,invoicing") do
      code, _, errors = run_command(Partiduo::Core::Commands::Provision, "--name=Foyer Martin", "--regime=fr",
        "--kind=household", "--modules=accounting,invoicing")
      code.should_not eq(0)
      errors.should contain("INVOICING")
      Partiduo::Core::Settings.all.count.should eq(0)
    end
  end
end
