# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Import et export du plan comptable en CSV, héritiers des outils du
    # plan comptable de l'application d'origine (D-OUT-004) : numéro,
    # libellé, parent, type, utilisation directe. Chaque ligne passe par les
    # commandes du contrat (`create_account`, `update_account`) : mêmes
    # contrôles qu'à la saisie (numéro normalisé, parent existant, compte
    # mouvementé jamais renuméroté). Service interne.
    module ChartImport
      alias FieldError = Partiduo::Api::FieldError
      alias Field = Partiduo::Api::Core::ImportFieldView
      alias Row = Partiduo::Api::Core::ImportRowView
      alias Action = Partiduo::Api::Core::ImportAction
      alias AccountKind = Partiduo::Api::Accounting::AccountKind
      alias CsvImport = Partiduo::Core::CsvImport

      FIELDS = [
        Field.new("number", "accounting.import.fields.number", required: true),
        Field.new("label", "accounting.import.fields.label", required: true),
        Field.new("parent", "accounting.import.fields.parent"),
        Field.new("kind", "accounting.import.fields.kind"),
        Field.new("direct_use", "accounting.import.fields.direct_use"),
      ]

      # Sans en-tête : l'ordre du format d'origine (numéro ; libellé ;
      # parent ; type).
      DEFAULT_COLUMNS = %w[number label parent kind]

      # Types du format d'origine : actif, passif, produit, charge, selon le
      # contexte ; suffixe `INV` : compte inversé (correctif).
      LEGACY_KINDS = {
        "ACT"    => AccountKind::Asset,
        "PAS"    => AccountKind::Liability,
        "PRO"    => AccountKind::Income,
        "CHA"    => AccountKind::Expense,
        "CON"    => AccountKind::Context,
        "ACTINV" => AccountKind::AssetContra,
        "PASINV" => AccountKind::LiabilityContra,
        "PROINV" => AccountKind::IncomeContra,
        "CHAINV" => AccountKind::ExpenseContra,
      }

      # Lit et traite le fichier dans la transaction de l'appelant (à blanc
      # pour l'aperçu). Les lignes sont traitées des numéros les plus courts
      # aux plus longs, pour qu'un parent précède ses comptes quel que soit
      # l'ordre du fichier ; le compte rendu garde l'ordre du fichier.
      def self.run(actor : Partiduo::Api::Actor, source : Partiduo::Api::Core::ImportSource) : Partiduo::Api::Core::ImportView
        records, errors = CsvImport.read(source)
        columns, records, header = CsvImport.associate(records, FIELDS, source.columns, DEFAULT_COLUMNS)
        errors.concat(CsvImport.column_errors(columns, FIELDS)) if errors.empty?
        rows = [] of Row
        if errors.empty?
          ordered = records.sort_by { |record| {Chart.normalize(CsvImport.values(record, columns)["number"]? || "").size, record.line} }
          rows = ordered.map { |record| row(actor, record, CsvImport.values(record, columns), source.update_existing) }
          rows.sort_by!(&.line)
        end
        Partiduo::Api::Core::ImportView.new(FIELDS, columns, header, rows, errors)
      end

      # Valeurs lues d'une ligne : type et utilisation directe (`nil` : non
      # saisis), parent.
      record Parsed, kind : AccountKind?, direct_use : Bool?, parent : String?

      private def self.row(actor : Partiduo::Api::Actor, record : CsvImport::Record, values : Hash(String, String),
                           update_existing : Bool) : Row
        values = values.transform_values { |value| CsvImport.unprotect(value) }
        number = Chart.normalize(values["number"]? || "")
        errors = [] of FieldError
        parsed = Parsed.new(kind(values["kind"]?.presence, errors), direct_use(values["direct_use"]?.presence, errors),
          parent(values["parent"]?.presence))
        return Row.new(record.line, record.cells, Action::Refused, number, errors) unless errors.empty?

        existing = number.empty? ? nil : Account.filter(number: number).first
        return create(actor, record, values, number, parsed) unless existing
        unless update_existing
          return Row.new(record.line, record.cells, Action::Refused, number,
            [FieldError.new("number", "accounting.errors.import.number_exists", {"number" => number})])
        end
        update(actor, record, values, existing, parsed)
      end

      private def self.create(actor : Partiduo::Api::Actor, record : CsvImport::Record, values : Hash(String, String),
                              number : String, parsed : Parsed) : Row
        direct_use = parsed.direct_use
        input = Partiduo::Api::Accounting::AccountInput.new(
          number: values["number"]? || "", label: values["label"]? || "", parent: parsed.parent, kind: parsed.kind,
          direct_use: direct_use.nil? ? true : direct_use)
        outcome(record, number, Partiduo::Api::Accounting.create_account(actor, input), Action::Create)
      end

      # Mise à jour : cellules non vides seulement ; le numéro ne change pas.
      private def self.update(actor : Partiduo::Api::Actor, record : CsvImport::Record, values : Hash(String, String),
                              existing : Account, parsed : Parsed) : Row
        direct_use = parsed.direct_use
        input = Partiduo::Api::Accounting::AccountInput.new(
          number: existing.number!, label: values["label"]?.presence || existing.label!,
          parent: parsed.parent || existing.parent.try(&.number), kind: parsed.kind || AccountKind.from_code(existing.kind!),
          direct_use: direct_use.nil? ? existing.direct_use == true : direct_use)
        result = Partiduo::Api::Accounting.update_account(actor, existing.pk!.as(Int64), input)
        outcome(record, existing.number!, result, Action::Update)
      end

      private def self.direct_use(text : String?, errors : Array(FieldError)) : Bool?
        return unless text
        flag = CsvImport.boolean(text)
        errors << FieldError.new("direct_use", "core.errors.import.boolean", {"value" => text}) if flag.nil?
        flag
      end

      private def self.outcome(record : CsvImport::Record, number : String,
                               result : Partiduo::Api::Result(Partiduo::Api::Accounting::AccountView), action : Action) : Row
        if view = result.value?
          Row.new(record.line, record.cells, action, view.number)
        else
          Row.new(record.line, record.cells, Action::Refused, number, result.errors)
        end
      end

      # Parent `0` du format d'origine (racine d'une classe) : aucun parent,
      # sauf si le plan a vraiment un compte `0`.
      private def self.parent(text : String?) : String?
        return unless text
        return if text.strip == "0" && !Account.filter(number: "0").exists?
        text
      end

      # Type saisi : code (`asset`), code d'origine (`ACT`, `PASINV`) ou
      # libellé dans l'une des langues ; vide : celui du parent.
      private def self.kind(text : String?, errors : Array(FieldError)) : AccountKind?
        return unless text
        wanted = text.strip
        if legacy = LEGACY_KINDS[wanted.upcase]?
          return legacy
        end
        AccountKind.values.each do |kind|
          return kind if kind.code == wanted.downcase
          Partiduo::LOCALES.each do |locale|
            label = I18n.with_locale(locale) { I18n.t("accounting.account_kinds.#{kind.code}") }
            return kind if label.downcase == wanted.downcase
          end
        end
        errors << FieldError.new("kind", "accounting.errors.import.kind", {"value" => wanted})
        nil
      end

      # --- Export ----------------------------------------------------------------

      # Plan comptable au format de l'import, dans l'ordre de l'arbre (un
      # parent avant ses comptes) : en-tête de libellés, type par son code,
      # utilisation directe `1` / `0`.
      def self.csv : Bytes
        CSV.build(separator: ';') do |csv|
          csv.row FIELDS.map { |field| Partiduo::Core::TableOutput.csv_text(field.title) }
          Chart.tree.each do |row|
            csv.row [Partiduo::Core::TableOutput.csv_text(row.number), Partiduo::Core::TableOutput.csv_text(row.label),
                     row.parent_number.to_s, row.kind, row.direct_use ? "1" : "0"]
          end
        end.to_slice
      end
    end
  end
end
