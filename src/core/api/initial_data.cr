# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Point d'accroche du jeu de données initial (ADR-001 D2 § Provisionnement,
    # convention C6) : chaque pièce du registre — socle, module ou extension —
    # déclare ce qu'elle charge dans une instance neuve, selon le régime fiscal
    # (plan comptable BE ou FR, journaux par défaut, catégories de fiches, taux
    # de TVA, profil administrateur…).
    #
    # `Partiduo::Api::Core.provision` exécute, dans sa transaction, les
    # chargeurs des pièces *actives*, par ordre croissant puis par nom. Un
    # chargeur qui lève annule tout le provisionnement. Il écrit par le contrat
    # (`Partiduo::Api::<App>`) avec `context.actor` (acteur système).
    #
    # ```
    # # src/accounting/initial_data.cr (lot 1)
    # Partiduo::Api::InitialData.register("ACCOUNTING", "chart_of_accounts", order: 10) do |context|
    #   Partiduo::Api::Accounting.load_chart(context.actor, regime: context.tax_regime)
    # end
    # ```
    #
    # *Type de dossier* (ADR-011 A3) : `company` (entreprise, défaut) ou
    # `household` (foyer), choisi au provisionnement et conservé par la
    # configuration du dossier. Le type décide du plan comptable de base
    # (`Kind#chart` : celui des entreprises du régime, ou le plan réduit d'un
    # foyer) et des modules admis. Une extension peut déclarer son propre
    # type (`register_kind`) et limiter ses chargeurs à certains types
    # (`register(…, kinds: […])`) : c'est ainsi qu'elle fournit les données
    # initiales d'un dossier.
    #
    # ```
    # Partiduo::Api::InitialData.register("PERSO", "categories", order: 30, kinds: ["household"]) do |context|
    #   Perso::Api.load_categories(context.actor, context.locale)
    # end
    # ```
    module InitialData
      # Type par défaut : un dossier d'entreprise, plan comptable du régime.
      COMPANY = "company"
      # Dossier d'un foyer (ADR-011) : plan réduit, sans module d'entreprise.
      HOUSEHOLD = "household"
      # Plans comptables de base que le module Comptabilité sait charger.
      CHARTS = [COMPANY, HOUSEHOLD]

      # Type de dossier. `owner` : pièce qui le déclare, qui doit être active
      # pour qu'on le choisisse. `chart` : plan de base (`CHARTS`).
      # `required` : modules qui doivent être actifs ; `excluded` : modules
      # qui ne peuvent pas l'être (codes du registre).
      record Kind, code : String, owner : String, chart : String,
        required : Array(String) = [] of String, excluded : Array(String) = [] of String

      @@kinds = {} of String => Kind

      # Déclare un type de dossier ; code en minuscules (`household`).
      def self.register_kind(code : String, owner : String, chart : String = COMPANY,
                             required : Array(String) = [] of String,
                             excluded : Array(String) = [] of String) : Kind
        unless code.matches?(/\A[a-z][a-z0-9_]*\z/)
          raise ArgumentError.new("type de dossier invalide (minuscules, chiffres, _) : #{code}")
        end
        raise ArgumentError.new("type de dossier déjà déclaré : #{code}") if @@kinds.has_key?(code)
        raise ArgumentError.new("plan de base inconnu pour #{code} : #{chart}") unless CHARTS.includes?(chart)
        @@kinds[code] = Kind.new(code, owner, chart, required, excluded)
      end

      # Type déclaré, actif ou non ; `nil` s'il est inconnu.
      def self.kind?(code : String) : Kind?
        @@kinds[code]?
      end

      @@exclusions = {} of String => Array(String)

      # Exclut une pièce d'un type de dossier (A-AMO-1), déclaré ou non
      # (une extension peut s'exclure d'un type qu'une autre déclare) :
      # même effet que `excluded:` de `register_kind` ou que
      # `incompatible_with_kind` au manifeste.
      def self.exclude(kind : String, code : String) : Nil
        list = (@@exclusions[kind] ||= [] of String)
        list << code unless list.includes?(code)
      end

      # Pièces qui ne peuvent pas être actives dans un dossier de type
      # `kind` : exclues par le type, par `exclude` ou par leur manifeste
      # (`incompatible_with_kind`). Contrôlé au provisionnement, à
      # l'activation et au démarrage (A-AMO-1).
      def self.excluded_modules(kind : String) : Array(String)
        codes = (@@kinds[kind]?.try(&.excluded) || [] of String).dup
        codes.concat(@@exclusions[kind]? || [] of String)
        Partiduo::Modules.manifests.each_value do |manifest|
          codes << manifest.code if manifest.incompatible_with_kind.includes?(kind)
        end
        codes.uniq
      end

      # Specs : retire une exclusion déclarée par un exemple.
      def self.unexclude(kind : String, code : String) : Nil
        @@exclusions[kind]?.try(&.delete(code))
      end

      # Types que l'on peut choisir : ceux dont la pièce est active.
      def self.kinds : Array(Kind)
        @@kinds.values.select { |kind| Partiduo::Modules.active?(kind.owner) }
      end

      # Specs : retire un type déclaré par un exemple.
      def self.unregister_kind(code : String) : Nil
        @@kinds.delete(code)
      end

      # Invitation émise pendant le provisionnement (compte de
      # l'administrateur) : rendue à l'opérateur par `ProvisionView`, seul
      # moyen de transmettre le jeton à l'administrateur d'une instance neuve.
      # `signup_code` : code de création du compte connect, à transmettre par
      # un autre canal que le lien (ADR-012 D6).
      record Invitation, email : String, token : String, expires_at : Time, signup_code : String = ""

      # Ce que reçoit un chargeur. `invitations` : un chargeur qui crée un
      # compte y dépose son jeton d'invitation. `kind` : type du dossier ;
      # `chart` : son plan comptable de base.
      record Context,
        actor : Actor,
        tax_regime : String,
        country_code : String,
        locale : String,
        admin_email : String?,
        module_codes : Array(String),
        invitations : Array(Invitation) = [] of Invitation,
        kind : String = COMPANY,
        chart : String = COMPANY

      # Chargeur ; `kinds` : types de dossier pour lesquels il s'exécute,
      # `nil` pour tous.
      record Loader, owner : String, name : String, order : Int32, block : Proc(Context, Nil),
        kinds : Array(String)? = nil do
        def id : String
          "#{owner}.#{name}"
        end

        def for?(kind : String) : Bool
          kinds.nil? || kinds.try(&.includes?(kind)) || false
        end
      end

      @@loaders = [] of Loader

      # Déclare un chargeur. `owner` : code du registre de la pièce qui le
      # déclare (`CORE`, `ACCOUNTING`, `SKEL`) ; il ne s'exécute que si cette
      # pièce est active. `name` : unique pour une pièce. `kinds` : types de
      # dossier pour lesquels il s'exécute (tous par défaut).
      def self.register(owner : String, name : String, order : Int32 = 100, kinds : Array(String)? = nil,
                        &block : Context -> Nil) : Nil
        loader = Loader.new(owner, name, order, block, kinds)
        if @@loaders.any?(&.id.==(loader.id))
          raise ArgumentError.new("chargeur de données initiales déjà déclaré : #{loader.id}")
        end
        @@loaders << loader
      end

      # Chargeurs des pièces actives pour un type de dossier, dans l'ordre
      # d'exécution.
      def self.loaders(kind : String = COMPANY) : Array(Loader)
        @@loaders
          .select { |loader| Partiduo::Modules.active?(loader.owner) && loader.for?(kind) }
          .sort_by! { |loader| {loader.order, loader.owner, loader.name} }
      end

      # Tous les chargeurs déclarés, actifs ou non.
      def self.all_loaders : Array(Loader)
        @@loaders.dup
      end

      # Exécute les chargeurs actifs ; renvoie leurs identifiants. Appelé par
      # `Partiduo::Api::Core.provision`, dans sa transaction.
      def self.run(context : Context) : Array(String)
        loaders(context.kind).map do |loader|
          loader.block.call(context)
          loader.id
        end
      end

      # Specs : retire un chargeur déclaré par un exemple.
      def self.unregister(owner : String, name : String) : Nil
        @@loaders.reject! { |loader| loader.owner == owner && loader.name == name }
      end
    end
  end
end
