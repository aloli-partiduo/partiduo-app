# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    module Cards
      # Import de fiches depuis un CSV (D-OUT-003) : permission propre, en
      # plus de `cards.card.write` qu'exige chaque fiche créée ou modifiée.
      IMPORT_PERMISSION = "cards.card.import"

      # Champs qu'une colonne peut alimenter pour une catégorie : nom (exigé,
      # sauf pour un fournisseur personne physique), quick code, champs de
      # la nature de la catégorie, attributs propres (`extra.<clé>`), compte
      # comptable (`account`) si la Comptabilité suit les fiches.
      def self.card_import_fields(actor : Actor, category_id : Int64) : Array(Core::ImportFieldView)
        Guard.authorize!(actor, IMPORT_PERMISSION, module_code: "CARDS")
        Partiduo::Cards::CardImport.fields(find_category(category_id))
      end

      # Aperçu à blanc : chaque ligne passe par `create_card` ou
      # `update_card`, puis tout est annulé. Une ligne dont le quick code
      # désigne une fiche existante la met à jour avec
      # `source.update_existing` (cellules non vides seulement ; même
      # catégorie, compte inchangé), sinon elle est refusée.
      def self.preview_card_import(actor : Actor, category_id : Int64, source : Core::ImportSource) : Core::ImportView
        authorize_import!(actor)
        category = find_category(category_id)
        Transaction.dry_run { Partiduo::Cards::CardImport.run(actor, category, source) }
      end

      # Importe le fichier dans une seule transaction. Échec, rien
      # d'enregistré : erreur générale, aucune ligne à importer, ou ligne
      # refusée sans `skip_refused` (`core.errors.import.has_refused`) ;
      # avec `skip_refused`, les lignes refusées sont écartées et le compte
      # rendu les cite.
      def self.import_cards(actor : Actor, category_id : Int64, source : Core::ImportSource,
                            skip_refused : Bool = false) : Result(Core::ImportView)
        authorize_import!(actor)
        category = find_category(category_id)
        Transaction.run do
          view = Partiduo::Cards::CardImport.run(actor, category, source)
          Partiduo::Core::CsvImport.outcome(view, skip_refused)
        end
      end

      # Fiches d'une catégorie au format de l'import (CSV, `;`, UTF-8,
      # en-tête de libellés) : relu tel quel avec `update_existing`.
      def self.export_cards(actor : Actor, category_id : Int64) : Core::FileView
        Guard.authorize!(actor, "cards.card.read", module_code: "CARDS")
        category = find_category(category_id)
        records = Partiduo::Cards::Card.filter(category_id: category.id).order(:code).to_a
        name = "#{I18n.t("cards.import.export_name")}-#{category.code}.csv"
        Core::FileView.new(name, "text/csv", Partiduo::Cards::CardImport.csv(category, card_views(records)))
      end

      private def self.authorize_import!(actor : Actor) : Nil
        Guard.authorize!(actor, IMPORT_PERMISSION, module_code: "CARDS")
        Guard.authorize!(actor, "cards.card.write", module_code: "CARDS")
      end
    end
  end
end
