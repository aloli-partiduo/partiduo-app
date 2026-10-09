# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du socle — types communs des imports CSV du cœur (fiches, plan
    # comptable ; D-OUT-002 à D-OUT-005). Chaque import suit le même
    # parcours : aperçu à blanc (`preview_*`), ligne par ligne, avec la suite
    # prévue (création, mise à jour) ou le motif du refus ; puis import
    # (`import_*`), qui rejoue les mêmes contrôles dans une seule
    # transaction. Rien ne passe d'office : avec une ligne refusée, l'import
    # échoue, sauf si l'appelant confirme explicitement d'écarter les lignes
    # refusées (`skip_refused`).
    module Core
      # Séparateurs et délimiteurs de texte admis, encodages lus.
      CSV_SEPARATORS = [';', ',', '\t', '|']
      CSV_QUOTES     = ['"', '\'']
      CSV_ENCODINGS  = %w[utf-8 windows-1252]
      # Taille et nombre de lignes au plus d'un fichier importé.
      CSV_MAX_BYTES = 5_000_000
      CSV_MAX_ROWS  =    10_000

      # Format d'un fichier CSV : séparateur, délimiteur de texte, encodage
      # (`CSV_ENCODINGS`), lignes à ignorer en tête (avant l'éventuel
      # en-tête).
      record CsvFormat,
        separator : Char = ';',
        quote : Char = '"',
        encoding : String = "utf-8",
        skip_rows : Int32 = 0

      # Fichier à importer : contenu brut, format, et colonnes associées aux
      # champs (`columns[i]` : clé du champ de la colonne `i`, `""` pour une
      # colonne ignorée). `columns` à `nil` : association reconnue d'après
      # la première ligne lue si c'est un en-tête (clés ou libellés des
      # champs, dans l'une des langues), sinon association par défaut de
      # l'import. `update_existing` : une ligne qui désigne une fiche ou un
      # compte existant le met à jour au lieu d'être refusée.
      record ImportSource,
        content : Bytes,
        format : CsvFormat = CsvFormat.new,
        columns : Array(String)? = nil,
        update_existing : Bool = false

      # Champ qu'une colonne peut alimenter : clé, libellé (clé i18n, ou
      # libellé déjà rédigé pour un attribut propre d'une catégorie de
      # fiches), obligatoire ou non.
      record ImportFieldView, key : String, label_key : String, required : Bool = false, label : String? = nil do
        # Libellé affiché, dans la langue courante.
        def title : String
          label || I18n.t(label_key)
        end
      end

      # Suite donnée à une ligne.
      enum ImportAction
        Create
        Update
        Refused

        # Valeur stable (`create`) ; libellé : `core.imports.actions.<code>`.
        def code : String
          to_s.underscore
        end
      end

      # Ligne lue : numéro d'enregistrement dans le fichier (1 pour le
      # premier), cellules, suite donnée, référence (quick code, numéro de
      # compte) et motifs du refus. Le champ d'une erreur est la clé du
      # champ importé (`siren`, `address.city`, `extra.ref`) ou `base`.
      record ImportRowView,
        line : Int32,
        cells : Array(String),
        action : ImportAction,
        reference : String,
        errors : Array(FieldError) = [] of FieldError do
        def refused? : Bool
          action.refused?
        end
      end

      # Aperçu ou compte rendu d'un import : champs proposés, association
      # retenue (une clé par colonne), en-tête reconnu, lignes, erreurs
      # générales (fichier illisible, colonne obligatoire manquante, champ
      # associé deux fois). `importable?` : au moins une ligne à importer et
      # aucune erreur générale.
      record ImportView,
        fields : Array(ImportFieldView),
        columns : Array(String),
        header : Bool,
        rows : Array(ImportRowView),
        errors : Array(FieldError) = [] of FieldError do
        def created_count : Int32
          rows.count(&.action.create?)
        end

        def updated_count : Int32
          rows.count(&.action.update?)
        end

        def refused_count : Int32
          rows.count(&.refused?)
        end

        def importable? : Bool
          errors.empty? && rows.any? { |row| !row.refused? }
        end

        # Champ d'une clé ; `nil` si la clé n'est pas proposée.
        def field(key : String) : ImportFieldView?
          fields.find(&.key.==(key))
        end
      end
    end
  end
end
