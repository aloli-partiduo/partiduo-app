# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Incompatibilités au manifeste (ADR-011 A1, amendement d'ADR-003 D2 ;
# DECISIONS D-FOY-001) : `incompatible_with` refuse, dans les deux sens,
# l'activation de deux pièces qui ne peuvent pas cohabiter, par le contrat
# comme au démarrage.

private def modules_admin : Partiduo::Api::Actor
  Partiduo::Api::Actor.user(42_i64, ["core.modules.manage"])
end

# Extension d'essai enregistrée le temps du bloc.
private def with_piece(& : Partiduo::Modules::Manifest ->) : Nil
  code = "INC#{Random::Secure.hex(3).upcase}"
  manifest = Partiduo::Modules.register { code code }
  begin
    yield manifest
  ensure
    Partiduo::Modules.manifests.delete(code)
  end
end

describe "Manifeste : incompatible_with (ADR-011 A1)" do
  it "garde les codes déclarés, sans doublon, et les expose au contrat" do
    with_piece do |piece|
      piece.incompatible_with "INVOICING", "MICRO"
      piece.incompatible_with "MICRO", "LIBERAL"
      piece.incompatible_with.should eq(%w[INVOICING MICRO LIBERAL])
      piece.incompatible?(Partiduo::Modules["INVOICING"]).should be_true
      Partiduo::Modules["INVOICING"].incompatible?(piece).should be_true
      piece.incompatible?(Partiduo::Modules["ACCOUNTING"]).should be_false
      Partiduo::Api::Modules.get(Partiduo::Api::Actor.system, piece.code).incompatible_with
        .should eq(%w[INVOICING MICRO LIBERAL])
    end
  end

  it "refuse un code mal formé ou la pièce elle-même" do
    with_piece do |piece|
      expect_raises(ArgumentError, /code de module invalide/) { piece.incompatible_with "invoicing" }
      expect_raises(ArgumentError, /lui-même/) { piece.incompatible_with piece.code }
    end
  end
end

describe "Activation par le contrat : incompatibilités dans les deux sens (ADR-011 A1)" do
  it "refuse d'activer la pièce qui se déclare incompatible avec une pièce active" do
    with_piece do |piece|
      piece.incompatible_with "INVOICING", "ANALYTIC"
      with_active_modules("accounting,invoicing,analytic") do
        result = Partiduo::Api::Modules.activate(modules_admin, piece.code)
        result.error_keys.should eq(["modules.errors.activation.incompatible_with"] * 2)
        result.errors.map(&.params["other"]).should eq(%w[INVOICING ANALYTIC])
        result.errors.first.params["module"].should eq(piece.code)
        result.errors.first.message.should contain("désactivez d'abord INVOICING")
        Partiduo::Modules.active?(piece.code).should be_false
      end
    end
  end

  it "refuse d'activer une pièce avec laquelle une pièce active se déclare incompatible" do
    with_piece do |piece|
      piece.incompatible_with "INVOICING"
      with_active_modules("accounting,#{piece.code.downcase}") do
        result = Partiduo::Api::Modules.activate(modules_admin, "INVOICING")
        result.error_keys.should eq(["modules.errors.activation.incompatible_with"])
        result.errors.first.params.should eq({"module" => "INVOICING", "other" => piece.code})
        Partiduo::Modules.active?("INVOICING").should be_false
        # Une pièce compatible s'active toujours.
        Partiduo::Api::Modules.activate(modules_admin, "ANALYTIC").success?.should be_true
      end
    end
  end

  it "accepte l'activation quand la pièce incompatible a été désactivée" do
    with_piece do |piece|
      piece.incompatible_with "INVOICING"
      with_active_modules("accounting,invoicing") do
        Partiduo::Api::Modules.activate(modules_admin, piece.code).success?.should be_false
        Partiduo::Api::Modules.deactivate(modules_admin, "INVOICING").success?.should be_true
        Partiduo::Api::Modules.activate(modules_admin, piece.code).value!.active.should be_true
      end
    end
  end

  it "ignore une pièce citée mais absente du registre (extension non installée)" do
    with_piece do |piece|
      piece.incompatible_with "TELEDEC_ABSENT"
      with_active_modules("accounting") do
        Partiduo::Api::Modules.activate(modules_admin, piece.code).success?.should be_true
      end
    end
  end

  it "traduit l'erreur en français, en anglais et en néerlandais" do
    {"fr" => "incompatible avec", "en" => "cannot be enabled together with", "nl" => "kan niet samen met"}.each do |locale, text|
      I18n.with_locale(locale) do
        message = I18n.t("modules.errors.activation.incompatible_with", module: "PERSO", other: "INVOICING")
        message.should contain(text)
        message.should contain("INVOICING")
      end
    end
  end
end

describe "Vérification au démarrage : incompatibilités (ADR-011 A1)" do
  it "refuse deux pièces incompatibles actives ensemble, citées une seule fois" do
    with_piece do |piece|
      piece.incompatible_with "INVOICING"
      with_active_modules("invoicing,#{piece.code.downcase}") do
        error = expect_raises(Partiduo::Modules::ConfigurationError) { Partiduo::Modules.check! }
        error.message.to_s.should contain("#{piece.code} est incompatible avec INVOICING, actifs ensemble")
      end
      with_piece do |other|
        other.incompatible_with piece.code
        piece.incompatible_with other.code
        errors = Partiduo::Modules.incompatibility_errors(Set{piece.code, other.code})
        errors.size.should eq(1)
      end
      with_active_modules("accounting,#{piece.code.downcase}") { Partiduo::Modules.check! }
    end
  end

  it "refuse une pièce qui dépend d'une pièce dont elle se déclare incompatible, ou du socle" do
    with_piece do |piece|
      piece.depends_on "ACCOUNTING"
      piece.incompatible_with "ACCOUNTING", "CARDS"
      errors = Partiduo::Modules.structure_errors
      errors.should contain("#{piece.code} dépend de ACCOUNTING et s'en déclare incompatible")
      errors.should contain("#{piece.code} se déclare incompatible avec CARDS, du socle : toujours actif")
    end
  end

  it "liste les pièces actives en conflit, quel que soit le côté qui déclare" do
    with_piece do |piece|
      piece.incompatible_with "INVOICING"
      active = Set{"INVOICING", "ACCOUNTING", piece.code}
      Partiduo::Modules.conflicts(piece.code, active).map(&.code).should eq(["INVOICING"])
      Partiduo::Modules.conflicts("INVOICING", active).map(&.code).should eq([piece.code])
      Partiduo::Modules.conflicts("ACCOUNTING", active).should be_empty
    end
  end
end
