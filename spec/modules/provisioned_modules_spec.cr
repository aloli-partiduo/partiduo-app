# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Démarrage sans `PARTIDUO_MODULES` (DECISIONS D-AMD-034) : la société
# retient les pièces actives au provisionnement, et une commande lancée sans
# l'environnement de l'instance les reprend au lieu du défaut
# (`accounting,invoicing,analytic`), que le contrôle des pièces exclues d'un
# type (D-AMD-005) refuserait pour un dossier foyer. Base pas encore migrée
# ou provisionnée : le défaut, comme avant.

private def provision_household : Nil
  settings = settings_input(company_name: "Foyer Martin", legal_form: nil, share_capital: nil, rcs: nil, siren: nil,
    vat_number: nil, domain: "martin.partiduo.localhost")
  Partiduo::Api::Core.provision(Partiduo::Api::Actor.system, Partiduo::Api::Core::ProvisionInput.new(
    settings: settings, modules: ["accounting"], kind: "household")).value!
end

private def recorded_modules : String?
  Marten::DB::Connection.default.open do |db|
    db.query_one?("SELECT provisioned_modules FROM core_settings ORDER BY id LIMIT 1", as: String?)
  end
end

private def forget_recorded_modules : Nil
  Marten::DB::Connection.default.open do |db|
    db.exec("UPDATE core_settings SET provisioned_modules = NULL")
  end
end

private def modules_admin : Partiduo::Api::Actor
  Partiduo::Api::Actor.user(42_i64, ["core.modules.manage"])
end

describe_module "ACCOUNTING", "Pièces retenues au provisionnement (D-AMD-034)" do
  it "retient les pièces actives, en majuscules et dans l'ordre" do
    with_active_modules("accounting") { provision_household }
    recorded_modules.should eq("ACCOUNTING")
  end

  it "démarre un dossier foyer sans PARTIDUO_MODULES : les pièces du dossier, pas le défaut" do
    with_active_modules("accounting") { provision_household }
    with_active_modules(nil) do
      Partiduo::Modules::State.active_codes.should eq(Set{"ACCOUNTING"})
      Partiduo::Modules.active?("INVOICING").should be_false
      Partiduo::Modules.active?("ANALYTIC").should be_false
      Partiduo::Modules.check!
    end
  end

  it "laisse PARTIDUO_MODULES, quand il est posé, l'emporter sur les pièces retenues" do
    with_active_modules("accounting") { provision_instance }
    with_active_modules("accounting,analytic") do
      Partiduo::Modules::State.active_codes.should eq(Set{"ACCOUNTING", "ANALYTIC"})
    end
  end

  it "laisse l'activation enregistrée par l'administrateur l'emporter sur les pièces retenues" do
    with_active_modules("accounting") { provision_instance }
    with_active_modules(nil) do
      Partiduo::Api::Modules.activate(modules_admin, "ANALYTIC").success?.should be_true
      Partiduo::Modules::State.active_codes.should eq(Set{"ACCOUNTING", "ANALYTIC"})
    end
  end

  it "retient un ensemble vide : le socle seul" do
    with_active_modules("none") do
      Partiduo::Api::Core.provision(Partiduo::Api::Actor.system,
        Partiduo::Api::Core::ProvisionInput.new(settings: settings_input)).value!
    end
    recorded_modules.should eq("")
    with_active_modules(nil) do
      Partiduo::Modules::State.active_codes.should be_empty
      Partiduo::Modules.active?("ACCOUNTING").should be_false
    end
  end

  it "garde le défaut avant le provisionnement" do
    with_active_modules(nil) do
      Partiduo::Modules::State.provisioned_codes.should be_nil
      Partiduo::Modules::State.active_codes.should eq(Set{"ACCOUNTING", "INVOICING", "ANALYTIC"})
    end
  end

  it "garde le défaut pour un dossier provisionné avant la colonne, et son refus pour un foyer" do
    with_active_modules("accounting") { provision_household }
    forget_recorded_modules
    with_active_modules(nil) do
      Partiduo::Modules::State.provisioned_codes.should be_nil
      Partiduo::Modules::State.active_codes.should eq(Set{"ACCOUNTING", "INVOICING", "ANALYTIC"})
      expect_raises(Partiduo::Modules::ConfigurationError, /exclu des dossiers de type household/) do
        Partiduo::Modules.check!
      end
    end
  end
end

describe "Configuration : PARTIDUO_MODULES posé ou absent" do
  it "distingue la variable absente (nil) de la variable vide ou none (socle seul)" do
    with_active_modules(nil) do
      Partiduo::Config.configured_module_codes.should be_nil
      Partiduo::Config.active_module_codes.should eq(Partiduo::Config::DEFAULT_MODULES.to_set)
    end
    with_active_modules("none") { Partiduo::Config.configured_module_codes.should eq(Set(String).new) }
    with_active_modules("") { Partiduo::Config.configured_module_codes.should eq(Set(String).new) }
    with_active_modules(" Accounting, perso ") do
      Partiduo::Config.configured_module_codes.should eq(Set{"accounting", "perso"})
    end
  end
end
