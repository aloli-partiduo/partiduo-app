# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Pièce exclue d'un type de dossier (A-AMO-1, DECISIONS D-AMD-005) :
# `incompatible_with_kind` au manifeste ou `InitialData.exclude`, contrôlé
# à l'activation, au démarrage (`check!`) et au provisionnement, comme les
# modules qu'un type exclut.

private def modules_admin : Partiduo::Api::Actor
  Partiduo::Api::Actor.user(42_i64, ["core.modules.manage"])
end

private def with_piece(& : Partiduo::Modules::Manifest ->) : Nil
  code = "KND#{Random::Secure.hex(3).upcase}"
  manifest = Partiduo::Modules.register { code code }
  begin
    yield manifest
  ensure
    Partiduo::Modules.manifests.delete(code)
  end
end

private def provision_household(modules = ["accounting"], extensions = [] of String) : Partiduo::Api::Result(Partiduo::Api::Core::ProvisionView)
  settings = settings_input(company_name: "Foyer Martin", legal_form: nil, share_capital: nil, rcs: nil, siren: nil,
    vat_number: nil, domain: "martin.partiduo.localhost")
  Partiduo::Api::Core.provision(Partiduo::Api::Actor.system, Partiduo::Api::Core::ProvisionInput.new(
    settings: settings, modules: modules, extensions: extensions, kind: "household"))
end

describe "Manifeste : incompatible_with_kind (A-AMO-1)" do
  it "garde les types déclarés, sans doublon, et les expose au contrat" do
    with_piece do |piece|
      piece.incompatible_with_kind "household"
      piece.incompatible_with_kind "household", "association"
      piece.incompatible_with_kind.should eq(%w[household association])
      Partiduo::Api::Modules.get(Partiduo::Api::Actor.system, piece.code).incompatible_with_kind
        .should eq(%w[household association])
      Partiduo::Api::InitialData.excluded_modules("household").should contain(piece.code)
      Partiduo::Api::InitialData.excluded_modules("company").should_not contain(piece.code)
      expect_raises(ArgumentError, /type de dossier invalide/) { piece.incompatible_with_kind "Foyer" }
    end
  end

  it "réunit les exclusions du type, d'InitialData.exclude et des manifestes" do
    with_piece do |piece|
      Partiduo::Api::InitialData.excluded_modules("household").should contain("INVOICING")
      Partiduo::Api::InitialData.exclude("household", piece.code)
      begin
        Partiduo::Api::InitialData.excluded_modules("household").count(piece.code).should eq(1)
        piece.incompatible_with_kind "household"
        Partiduo::Api::InitialData.excluded_modules("household").count(piece.code).should eq(1)
      ensure
        Partiduo::Api::InitialData.unexclude("household", piece.code)
      end
    end
  end
end

describe_module "ACCOUNTING", "Pièce exclue d'un dossier foyer (A-AMO-1)" do
  it "refuse l'activation dans un dossier foyer, l'accepte dans un dossier d'entreprise" do
    with_piece do |piece|
      piece.incompatible_with_kind "household"
      with_active_modules("accounting") do
        provision_household.value!
        result = Partiduo::Api::Modules.activate(modules_admin, piece.code)
        result.error_keys.should eq(["modules.errors.activation.excluded_kind"])
        result.errors.first.params.should eq({"module" => piece.code, "kind" => "household"})
        result.errors.first.message.should contain("household")
        Partiduo::Modules.active?(piece.code).should be_false
        # Un module d'entreprise que le type exclut est refusé de même.
        Partiduo::Api::Modules.activate(modules_admin, "ANALYTIC").error_keys
          .should eq(["modules.errors.activation.excluded_kind"])
      end
    end
  end

  it "accepte l'activation dans un dossier d'entreprise" do
    with_piece do |piece|
      piece.incompatible_with_kind "household"
      with_active_modules("accounting") do
        provision_instance
        Partiduo::Api::Modules.activate(modules_admin, piece.code).success?.should be_true
      end
    end
  end

  it "refuse le provisionnement d'un foyer avec la pièce active, et le démarrage si elle l'est" do
    with_piece do |piece|
      piece.incompatible_with_kind "household"
      with_active_modules("accounting,#{piece.code.downcase}") do
        result = provision_household(extensions: [piece.code])
        result.error_keys.should contain("core.errors.provision.kind.excluded")
      end
      with_active_modules("accounting") { provision_household.value! }
      with_active_modules("accounting,#{piece.code.downcase}") do
        Partiduo::Modules.kind_errors(Partiduo::Modules::State.active_codes, "household")
          .should eq(["#{piece.code} est exclu des dossiers de type household, actif"])
        expect_raises(Partiduo::Modules::ConfigurationError, /exclu des dossiers de type household/) do
          Partiduo::Modules.check!
        end
      end
    end
  end
end
