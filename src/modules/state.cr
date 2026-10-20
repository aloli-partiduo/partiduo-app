# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Modules
    # Ensemble des modules et extensions actifs sur l'instance (ADR-006 D2).
    #
    # Source, par ordre de priorité (D-018) :
    #
    # . la table `modules_activation`, dès qu'elle contient une ligne —
    #   l'administrateur a enregistré un choix (`Partiduo::Api::Modules.activate`) ;
    # . sinon `PARTIDUO_MODULES` (`Partiduo::Config.configured_module_codes`) :
    #   valeur initiale de l'instance, configuration des specs et de la CI ;
    # . sinon, variable absente, les pièces actives au provisionnement,
    #   retenues par la société (`core_settings.provisioned_modules`,
    #   D-AMD-034) : une commande lancée sans l'environnement de l'instance
    #   voit les pièces du dossier, pas le défaut ;
    # . sinon (base pas encore migrée ni provisionnée, ou injoignable) le
    #   défaut `Partiduo::Config::DEFAULT_MODULES`.
    #
    # La table est relue à chaque appel (une requête courte) : plusieurs
    # processus d'une même instance voient le même état sans cache à invalider.
    module State
      TABLE = "modules_activation"

      @@table_ready = false
      @@provisioned_column = false

      # Codes (en majuscules) des pièces *non socle* actives.
      def self.active_codes : Set(String)
        stored_codes ||
          Partiduo::Config.configured_module_codes.try(&.map(&.upcase).to_set) ||
          provisioned_codes ||
          Partiduo::Config::DEFAULT_MODULES.map(&.upcase).to_set
      end

      # Codes actifs enregistrés en base, ou `nil` si rien n'est enregistré
      # (table vide, absente avant `migrate`, ou base injoignable au démarrage
      # d'une commande comme `migrate` elle-même).
      def self.stored_codes : Set(String)?
        return unless table_ready?

        rows = Activation.all.to_a
        return if rows.empty?

        rows.select(&.active).compact_map(&.code).to_set
      end

      # Enregistre l'ensemble actif complet : une ligne par pièce non socle
      # enregistrée ou déjà présente en base.
      def self.save(active : Set(String), changed_by : Int64? = nil) : Nil
        codes = Partiduo::Modules.manifests.values.reject(&.socle?).map(&.code).to_set
        Activation.all.each { |row| row.code.try { |code| codes << code } }

        codes.each do |code|
          row = Activation.get(code: code) || Activation.new(code: code)
          next if row.persisted? && row.active == active.includes?(code)

          row.active = active.includes?(code)
          row.changed_by_id = changed_by
          row.save!
        end
      end

      # La table existe-t-elle ? Mémorisé une fois vrai ; `to_regclass` ne lève
      # pas d'erreur (une erreur SQL annulerait la transaction en cours).
      def self.table_ready? : Bool
        return true if @@table_ready

        exists = Marten::DB::Connection.default.open do |db|
          !db.scalar("SELECT to_regclass($1)::text", TABLE).nil?
        end
        @@table_ready = exists
      rescue DB::ConnectionRefused | Marten::DB::Errors::UnknownConnection
        # Base injoignable, ou connexions pas encore configurées (avant
        # `Marten.setup`, au chargement des specs) : rien d'enregistré.
        false
      end

      # Type du dossier (`core_settings.kind`, ADR-011 A3), ou `nil` avant
      # le provisionnement ou si la base est injoignable : lu pour le
      # contrôle des pièces exclues d'un type (A-AMO-1). Sans erreur SQL, qui
      # annulerait la transaction en cours.
      def self.folder_kind : String?
        Marten::DB::Connection.default.open do |db|
          next if db.scalar("SELECT to_regclass('core_settings')::text").nil?
          db.query_one?("SELECT kind FROM core_settings ORDER BY id LIMIT 1", as: String)
        end
      rescue DB::ConnectionRefused | Marten::DB::Errors::UnknownConnection
        nil
      end

      # Pièces non socle actives au provisionnement (`Api::Core.provision`),
      # retenues par la société ; `nil` si rien n'est lisible : base pas
      # encore migrée (colonne absente, migration core 0008), dossier pas
      # encore provisionné ou provisionné avant cette colonne, base
      # injoignable. Sans erreur SQL, qui annulerait la transaction en cours.
      def self.provisioned_codes : Set(String)?
        return unless provisioned_column?

        text = Marten::DB::Connection.default.open do |db|
          db.query_one?("SELECT provisioned_modules FROM core_settings ORDER BY id LIMIT 1", as: String?)
        end
        text.try { |value| value.split(',').map(&.strip.upcase).reject(&.empty?).to_set }
      rescue DB::ConnectionRefused | Marten::DB::Errors::UnknownConnection
        nil
      end

      # La colonne `core_settings.provisioned_modules` existe-t-elle ?
      # Mémorisé une fois vrai, comme `table_ready?`.
      def self.provisioned_column? : Bool
        return true if @@provisioned_column

        exists = Marten::DB::Connection.default.open do |db|
          !db.query_one?(<<-SQL, as: Int32).nil?
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = current_schema() AND table_name = 'core_settings'
              AND column_name = 'provisioned_modules'
            SQL
        end
        @@provisioned_column = exists
      rescue DB::ConnectionRefused | Marten::DB::Errors::UnknownConnection
        false
      end

      # Pour les specs qui recréent le schéma.
      def self.reset_table_cache : Nil
        @@table_ready = false
        @@provisioned_column = false
      end
    end
  end
end
