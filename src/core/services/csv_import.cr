# SPDX-License-Identifier: AGPL-3.0-or-later

require "csv"

module Partiduo
  module Core
    # Lecture des fichiers CSV importés et outils communs aux imports du
    # cœur (D-OUT-002 à D-OUT-005) : décodage, découpage, association des
    # colonnes aux champs, lecture des nombres, dates et booléens saisis à
    # la française, à l'anglaise ou à la néerlandaise. Service interne : les
    # imports passent par `Partiduo::Api::Cards` et
    # `Partiduo::Api::Accounting`.
    module CsvImport
      alias FieldError = Partiduo::Api::FieldError
      alias Source = Partiduo::Api::Core::ImportSource
      alias Field = Partiduo::Api::Core::ImportFieldView

      # Enregistrement lu : numéro (1 pour le premier du fichier) et cellules.
      record Record, line : Int32, cells : Array(String)

      UTF8_BOM = Bytes[0xEF, 0xBB, 0xBF]

      TRUE_WORDS  = %w[1 o oui y yes j ja true vrai waar x]
      FALSE_WORDS = %w[0 n non no nee false faux onwaar]

      # Enregistrements du fichier, lignes à ignorer retirées, lignes vides
      # écartées ; erreurs générales si le fichier est illisible.
      def self.read(source : Source) : {Array(Record), Array(FieldError)}
        errors = format_errors(source.format)
        return {[] of Record, errors} unless errors.empty?
        content = source.content
        if content.size > Partiduo::Api::Core::CSV_MAX_BYTES
          return {[] of Record, [error("too_large", {"max" => (Partiduo::Api::Core::CSV_MAX_BYTES // 1_000_000).to_s})]}
        end
        text = decode(content, source.format.encoding)
        return {[] of Record, [error("encoding")]} unless text
        parse(text, source.format)
      end

      private def self.format_errors(format : Partiduo::Api::Core::CsvFormat) : Array(FieldError)
        errors = [] of FieldError
        errors << FieldError.new("separator", "core.errors.import.separator") unless Partiduo::Api::Core::CSV_SEPARATORS.includes?(format.separator)
        errors << FieldError.new("quote", "core.errors.import.quote") unless Partiduo::Api::Core::CSV_QUOTES.includes?(format.quote)
        errors << FieldError.new("encoding", "core.errors.import.encoding_unknown") unless Partiduo::Api::Core::CSV_ENCODINGS.includes?(format.encoding)
        errors << FieldError.new("skip_rows", "core.errors.import.skip_rows") unless format.skip_rows.in?(0..1000)
        errors
      end

      # Texte du fichier ; `nil` si un fichier annoncé en UTF-8 ne l'est pas.
      private def self.decode(content : Bytes, encoding : String) : String?
        if encoding == "windows-1252"
          String.new(content, "WINDOWS-1252", invalid: :skip)
        else
          content = content[UTF8_BOM.size..] if content.size >= UTF8_BOM.size && content[0, UTF8_BOM.size] == UTF8_BOM
          text = String.new(content)
          text.valid_encoding? ? text : nil
        end
      end

      private def self.parse(text : String, format : Partiduo::Api::Core::CsvFormat) : {Array(Record), Array(FieldError)}
        records = [] of Record
        line = 0
        begin
          CSV.each_row(text, separator: format.separator, quote_char: format.quote) do |cells|
            line += 1
            next if line <= format.skip_rows
            next if cells.all?(&.strip.empty?)
            if records.size >= Partiduo::Api::Core::CSV_MAX_ROWS
              return {[] of Record, [error("too_many_rows", {"max" => Partiduo::Api::Core::CSV_MAX_ROWS.to_s})]}
            end
            records << Record.new(line, cells.map(&.strip))
          end
        rescue CSV::MalformedCSVError
          return {[] of Record, [error("malformed", {"line" => (line + 1).to_s})]}
        end
        return {records, [error("empty")]} if records.empty?
        {records, [] of FieldError}
      end

      # Association des colonnes : celle demandée ; sinon l'en-tête reconnu
      # dans le premier enregistrement (retiré des données) ; sinon
      # `defaults`. Complétée de colonnes ignorées jusqu'à la largeur du
      # fichier. Renvoie l'association, les enregistrements de données et
      # si un en-tête a été reconnu.
      def self.associate(records : Array(Record), fields : Array(Field), given : Array(String)?,
                         defaults : Array(String)) : {Array(String), Array(Record), Bool}
        width = records.max_of?(&.cells.size) || 0
        header = false
        columns = if given
                    given.map(&.strip)
                  elsif (first = records.first?) && (recognized = header_columns(first.cells, fields))
                    header = true
                    records = records[1..]
                    recognized
                  else
                    defaults.dup
                  end
        columns = columns.first(Math.max(width, given.try(&.size) || 0))
        columns.concat([""] * (width - columns.size)) if columns.size < width
        {columns, records, header}
      end

      # Erreurs de l'association : champ inconnu, champ associé deux fois,
      # champ obligatoire absent.
      def self.column_errors(columns : Array(String), fields : Array(Field)) : Array(FieldError)
        errors = [] of FieldError
        known = fields.map(&.key).to_set
        columns.each_with_index do |key, index|
          next if key.empty?
          unless known.includes?(key)
            errors << FieldError.new("columns[#{index}]", "core.errors.import.column_unknown",
              {"column" => (index + 1).to_s, "key" => key})
          end
        end
        columns.reject(&.empty?).tally.each do |key, count|
          next if count < 2
          title = fields.find(&.key.==(key)).try(&.title) || key
          errors << FieldError.new("columns", "core.errors.import.column_duplicate", {"field" => title})
        end
        fields.select(&.required).each do |field|
          next if columns.includes?(field.key)
          errors << FieldError.new("columns", "core.errors.import.column_missing", {"field" => field.title})
        end
        errors
      end

      # Valeurs d'un enregistrement, par clé de champ (colonnes ignorées et
      # cellules absentes omises).
      def self.values(record : Record, columns : Array(String)) : Hash(String, String)
        values = {} of String => String
        columns.each_with_index do |key, index|
          next if key.empty?
          values[key] = record.cells[index]? || ""
        end
        values
      end

      # En-tête : au moins la moitié des cellules non vides reconnues comme
      # la clé ou le libellé d'un champ (dans l'une des langues).
      private def self.header_columns(cells : Array(String), fields : Array(Field)) : Array(String)?
        names = {} of String => String
        fields.each do |field|
          names[simplify(field.key)] = field.key
          if label = field.label
            names[simplify(label)] = field.key
          else
            Partiduo::LOCALES.each do |locale|
              I18n.with_locale(locale) { names[simplify(I18n.t(field.label_key))] = field.key }
            end
          end
        end
        columns = cells.map { |cell| names[simplify(cell)]? || "" }
        filled = cells.count { |cell| !cell.empty? }
        found = columns.count { |key| !key.empty? }
        return if found.zero? || found * 2 < filled
        seen = Set(String).new
        columns.map { |key| seen.add?(key) ? key : "" }
      end

      private def self.simplify(text : String) : String
        text.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/[^a-z0-9.]+/, " ").strip
      end

      # --- Valeurs ---------------------------------------------------------------

      # Une cellule protégée contre les formules par un export du cœur
      # (`'=…`, `'+33…`, `TableOutput.csv_text`) est relue sans l'apostrophe.
      def self.unprotect(value : String) : String
        value.matches?(/\A'[=+\-@\t\r]/) ? value[1..] : value
      end

      # Nombre décimal saisi (`1 234,56`, `1,234.56`, `1234.56`, `-3`) ;
      # `nil` s'il n'en est pas un. Jamais de flottant.
      def self.decimal(text : String) : BigDecimal?
        value = text.gsub(/[\s  ']/, "")
        return if value.empty?
        comma = value.rindex(',')
        dot = value.rindex('.')
        if comma && dot
          value = comma > dot ? value.delete('.').tr(",", ".") : value.delete(',')
        elsif comma
          value = value.tr(",", ".")
        end
        return unless value.matches?(/\A[-+]?\d+(\.\d+)?\z/)
        BigDecimal.new(value.lchop('+'))
      end

      # Date saisie (`AAAA-MM-JJ`, `JJ/MM/AAAA`, `JJ.MM.AAAA`, `JJ-MM-AAAA`) ;
      # `nil` si elle n'en est pas une.
      def self.date(text : String) : Time?
        value = text.strip
        if match = value.match(/\A(\d{4})-(\d{1,2})-(\d{1,2})\z/)
          build_date(match[1], match[2], match[3])
        elsif match = value.match(/\A(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{4})\z/)
          build_date(match[3], match[2], match[1])
        end
      end

      private def self.build_date(year : String, month : String, day : String) : Time?
        Time.utc(year.to_i, month.to_i, day.to_i)
      rescue ArgumentError
        nil
      end

      # Booléen saisi (`oui`, `non`, `1`, `0`, `x`, `ja`, `nee`…) ; `nil`
      # s'il n'est pas reconnu.
      def self.boolean(text : String) : Bool?
        value = text.strip.downcase
        return true if TRUE_WORDS.includes?(value)
        false if FALSE_WORDS.includes?(value)
      end

      # Issue d'un import réel (dans sa transaction) : échec, donc tout
      # annulé, sur une erreur générale, sans ligne à importer, ou avec une
      # ligne refusée que l'appelant n'a pas demandé d'écarter.
      def self.outcome(view : Partiduo::Api::Core::ImportView,
                       skip_refused : Bool) : Partiduo::Api::Result(Partiduo::Api::Core::ImportView)
        result = Partiduo::Api::Result(Partiduo::Api::Core::ImportView)
        return result.failure(view.errors) unless view.errors.empty?
        refused = view.refused_count
        if refused > 0 && !skip_refused
          return result.failure(error("has_refused", {"count" => refused.to_s}))
        end
        return result.failure(error("nothing")) unless view.importable?
        result.success(view)
      end

      def self.error(code : String, params : Hash(String, String) = {} of String => String) : FieldError
        FieldError.base("core.errors.import.#{code}", params)
      end
    end
  end
end
