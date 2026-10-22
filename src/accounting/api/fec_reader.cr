# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Comptabilité — lecture d'un fichier des écritures
    # comptables (A-IMP-4), commune aux outils qui reprennent un FEC : la
    # reprise d'un dossier entier (`partiduo-migrate`) et l'import dans un
    # dossier existant (`partiduo-import`). Le cœur l'exporte déjà
    # (`Accounting.fec`) ; il le relit ici sans rien écrire. Référence :
    # `doc/api/accounting-fec-reader.adoc`.
    module Accounting
      # Ligne lue. `debit` et `credit` : solde de la ligne (un débit et un
      # crédit écrits sur la même ligne sont compensés, l'un des deux est
      # nul) ; `raw_debit` et `raw_credit` : montants tels qu'écrits, pour un
      # contrôle de lecture. `row` : numéro de la ligne dans le fichier
      # (l'en-tête est la ligne 1).
      record FecLineView,
        row : Int32,
        account_number : String,
        account_label : String,
        aux_number : String?,
        aux_label : String?,
        label : String,
        debit : BigDecimal,
        credit : BigDecimal,
        raw_debit : BigDecimal,
        raw_credit : BigDecimal,
        letter : String?,
        letter_date : Time?,
        valid_date : Time?,
        currency_amount : BigDecimal?,
        currency_code : String?

      # Écriture du fichier : lignes d'un même `EcritureNum` dans un même
      # `JournalCode`, dans l'ordre du fichier. `receipt` : `PieceRef` ;
      # `label` : `EcritureLib` de sa première ligne ; `due_date` : première
      # échéance lue dans une zone facultative (`DateEcheance`,
      # `EcheanceDate`, `DateEch`).
      record FecEntryView,
        row : Int32,
        journal_code : String,
        journal_label : String,
        number : String,
        date : Time,
        receipt : String,
        receipt_date : Time?,
        label : String,
        due_date : Time?,
        lines : Array(FecLineView) do
        def total_debit : BigDecimal
          lines.sum(BigDecimal.new(0), &.debit)
        end

        def total_credit : BigDecimal
          lines.sum(BigDecimal.new(0), &.credit)
        end

        def balanced? : Bool
          total_debit == total_credit
        end

        # Référence lisible : `<journal>/<numéro>`.
        def reference : String
          "#{journal_code}/#{number}"
        end
      end

      # Défaut ou avertissement de lecture : ligne du fichier (1 = en-tête,
      # 0 = fichier entier), zone en cause (vide si aucune), clé i18n
      # (`accounting.fec_reader.issues.*`) et paramètres.
      record FecIssueView, row : Int32, column : String, key : String,
        params : Hash(String, String) = {} of String => String do
        def message : String
          I18n.t(key, params)
        end
      end

      # Fichier lu. `issues` : défauts qui empêchent de reprendre le fichier
      # (zone manquante, montant ou date illisible, écriture déséquilibrée…) ;
      # `warnings` : remarques qui ne l'empêchent pas (encodage douteux).
      # `encoding` : encodage retenu ; `separator` : séparateur reconnu ;
      # `columns` : zones de l'en-tête ; `zero_lines` : lignes sans effet
      # (débit égal au crédit), ignorées ; `raw_debit`, `raw_credit` : totaux
      # des montants tels qu'écrits, lignes sans effet exclues.
      record FecFileView,
        encoding : String,
        separator : Char,
        columns : Array(String),
        entries : Array(FecEntryView),
        issues : Array(FecIssueView),
        warnings : Array(FecIssueView),
        zero_lines : Int32,
        raw_debit : BigDecimal,
        raw_credit : BigDecimal do
        def valid? : Bool
          issues.empty?
        end

        # Libellés des journaux, des comptes et des comptes auxiliaires
        # rencontrés, par code, dans l'ordre du fichier.
        def journals : Hash(String, String)
          entries.each_with_object({} of String => String) { |entry, map| map[entry.journal_code] ||= entry.journal_label }
        end

        def accounts : Hash(String, String)
          entries.each_with_object({} of String => String) do |entry, map|
            rows = entry.lines
            rows.each { |line| map[line.account_number] ||= line.account_label }
          end
        end

        def parties : Hash(String, String)
          entries.each_with_object({} of String => String) do |entry, map|
            rows = entry.lines
            rows.each { |line| line.aux_number.try { |code| map[code] ||= line.aux_label || "" } }
          end
        end
      end

      # Encodages qu'on peut imposer à `read_fec` (sinon reconnu : BOM,
      # UTF-8 valide, ISO 8859-15, Windows-1252).
      FEC_ENCODINGS = Partiduo::Accounting::FecReader::ENCODINGS.keys

      # Lit un FEC (A-IMP-4), sans rien écrire ni lire en base. Tout
      # utilisateur authentifié au niveau exigé, même Comptabilité inactive
      # (D-AMD-037) : un simple contrôle de fichier, avant la reprise d'un
      # dossier qui n'a pas encore la Comptabilité, ne doit pas l'exiger.
      #
      # * `encoding` : `nil` ou `auto` pour le reconnaître, sinon un nom de
      #   `FEC_ENCODINGS` (`utf-8`, `iso-8859-15`, `windows-1252`…) ;
      # * `strict` : exiger les zones de l'article A47 A-1 (sauf
      #   `Montantdevise` et `Idevise`, absentes des fichiers antérieurs à
      #   2014) ; sinon seules `JournalCode`, `EcritureNum`, `EcritureDate`,
      #   `CompteNum` et les montants (`Debit` et `Credit`, ou `Montant` et
      #   `Sens`) le sont.
      #
      # Séparateur tabulation ou barre verticale (point-virgule toléré hors
      # de `strict`) ; zones reconnues par leur nom, sans égard à la casse ;
      # séparateur terminal toléré ; valeurs entre guillemets dégagées ;
      # dates `AAAAMMJJ` (`AAAA-MM-JJ` et `JJ/MM/AAAA` tolérées) ; montants
      # à virgule ou point décimal, blancs et `+` admis.
      def self.read_fec(actor : Actor, content : Bytes, encoding : String? = nil, strict : Bool = false) : FecFileView
        Guard.authorize!(actor, nil)
        Partiduo::Accounting::FecReader.read(content, encoding, strict)
      end
    end
  end
end
