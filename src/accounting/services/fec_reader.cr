# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Lecture d'un fichier des écritures comptables (A-IMP-4) : le meilleur
    # des deux lecteurs qui l'ont précédé, celui de la reprise d'un dossier
    # (encodages, contrôle des zones de l'arrêté, équilibre des écritures,
    # totaux de lecture) et celui de l'import dans un dossier existant
    # (point-virgule, zones minimales, échéance). Service interne, appelé par
    # `Partiduo::Api::Accounting.read_fec`.
    module FecReader
      alias Api = Partiduo::Api::Accounting

      # Zones de l'article A47 A-1 exigées en lecture stricte (`Montantdevise`
      # et `Idevise` tolérées absentes : fichiers antérieurs à 2014).
      STRICT = %w[JournalCode JournalLib EcritureNum EcritureDate CompteNum CompteLib CompAuxNum CompAuxLib
        PieceRef PieceDate EcritureLib EcritureLet DateLet ValidDate]
      # Zones exigées en lecture souple.
      MINIMAL = %w[JournalCode EcritureNum EcritureDate CompteNum]
      # Zones d'échéance reconnues au-delà des dix-huit (non normalisées).
      DUE_DATES = %w[DateEcheance EcheanceDate DateEch]

      # Encodages qu'on peut imposer, et leur nom canonique.
      ENCODINGS = {
        "utf-8"        => "UTF-8",
        "utf8"         => "UTF-8",
        "iso-8859-15"  => "ISO-8859-15",
        "iso8859-15"   => "ISO-8859-15",
        "latin9"       => "ISO-8859-15",
        "iso-8859-1"   => "ISO-8859-1",
        "latin1"       => "ISO-8859-1",
        "windows-1252" => "WINDOWS-1252",
        "cp1252"       => "WINDOWS-1252",
        "ascii"        => "ASCII",
        "utf-16"       => "UTF-16",
      }

      UTF8_BOM = Bytes[0xEF, 0xBB, 0xBF]

      ZERO = BigDecimal.new(0)

      # Problème rencontré : refus ou avertissement (clé sans préfixe).
      class Failure < Exception
        getter key : String
        getter params : Hash(String, String)

        def initialize(@key : String, @params = {} of String => String)
          super(key)
        end
      end

      # État d'une lecture.
      private class Reading
        getter issues = [] of Api::FecIssueView
        getter warnings = [] of Api::FecIssueView
        getter entries = [] of Api::FecEntryView
        getter groups = {} of {String, String} => Int32
        property encoding = ""
        property separator = '\t'
        property columns = [] of String
        property zero_lines = 0
        property raw_debit = BigDecimal.new(0)
        property raw_credit = BigDecimal.new(0)

        def issue(row : Int32, column : String, key : String, params = {} of String => String) : Nil
          @issues << Api::FecIssueView.new(row, column, "accounting.fec_reader.issues.#{key}", params)
        end

        def warning(row : Int32, column : String, key : String, params = {} of String => String) : Nil
          @warnings << Api::FecIssueView.new(row, column, "accounting.fec_reader.issues.#{key}", params)
        end

        def view : Api::FecFileView
          Api::FecFileView.new(encoding: encoding, separator: separator, columns: columns, entries: entries,
            issues: issues, warnings: warnings, zero_lines: zero_lines, raw_debit: raw_debit, raw_credit: raw_credit)
        end
      end

      def self.read(bytes : Bytes, encoding : String?, strict : Bool) : Api::FecFileView
        reading = Reading.new
        text = begin
          decode(bytes, encoding, reading)
        rescue ex : Failure
          reading.issue(0, "", ex.key, ex.params)
          return reading.view
        end
        reading.warning(0, "", "c1_characters", {"encoding" => reading.encoding}) if c1?(text)
        lines = text.split(/\r\n|\n|\r/)
        while lines.last?.try(&.strip.empty?)
          lines.pop
        end
        layout = header(lines.first?, strict, reading) || return reading.view
        lines.each_with_index do |raw, position|
          next if position.zero? || raw.strip.empty?
          fields = layout.fields(raw, position + 1, reading) || next
          read_line(fields, reading)
        end
        check_balance(reading)
        reading.issue(0, "", "no_entry") if reading.entries.empty? && reading.issues.empty?
        reading.view
      end

      # Disposition du fichier lue sur l'en-tête : séparateur, zones, position
      # de chaque zone, séparateur terminal toléré.
      private record Layout, separator : Char, columns : Array(String), index : Hash(String, Int32), trailing : Bool do
        # Zones d'une ligne ; `nil` (et un défaut) si leur nombre n'est pas
        # celui de l'en-tête. Séparateur terminal annoncé par l'en-tête :
        # zone finale vide tolérée ; toute autre zone en trop décalerait les
        # suivantes (séparateur dans un libellé).
        def fields(raw : String, row : Int32, reading : Reading) : Fields?
          values = FecReader.split(raw, separator)
          values.pop if trailing && values.size == columns.size + 1 && values.last.empty?
          if values.size != columns.size
            reading.issue(row, "", "field_count", {"count" => values.size.to_s, "expected" => columns.size.to_s})
            return
          end
          Fields.new(values, index, row)
        end
      end

      private def self.header(line : String?, strict : Bool, reading : Reading) : Layout?
        if line.nil? || line.strip.empty?
          reading.issue(1, "", "empty_file")
          return
        end
        separator = separator(line, strict)
        if separator.nil?
          reading.issue(1, "", strict ? "separator_strict" : "separator")
          return
        end
        reading.separator = separator
        columns = split(line, separator)
        trailing = columns.size > 1 && columns.last.empty?
        columns.pop if trailing
        reading.columns = columns
        index = column_index(columns, strict, reading) || return
        Layout.new(separator, columns, index, trailing)
      end

      private def self.check_balance(reading : Reading) : Nil
        reading.entries.each do |entry|
          next if entry.balanced?
          reading.issue(entry.row, "EcritureNum", "unbalanced",
            {"entry" => entry.reference, "debit" => entry.total_debit.to_s, "credit" => entry.total_credit.to_s})
        end
      end

      # --- Encodage ------------------------------------------------------------

      # Texte du fichier. Encodage imposé, sinon reconnu : BOM UTF-8 ou
      # UTF-16, UTF-8 valide, ISO 8859-15 — ou Windows-1252 si l'ISO 8859-15
      # donne des caractères de contrôle C1 (€ et apostrophes de Windows).
      private def self.decode(bytes : Bytes, forced : String?, reading : Reading) : String
        wanted = forced.try(&.strip.downcase)
        return decode_as(bytes, forced.to_s, wanted, reading) if wanted && !wanted.empty? && wanted != "auto"
        if bytes[0, 3]? == UTF8_BOM
          reading.encoding = "UTF-8"
          return utf8!(bytes[3..])
        end
        if bytes[0, 2]?.in?(Bytes[0xFF, 0xFE], Bytes[0xFE, 0xFF])
          reading.encoding = "UTF-16"
          return convert(bytes, "UTF-16")
        end
        text = String.new(bytes)
        if text.valid_encoding?
          reading.encoding = text.ascii_only? ? "ASCII" : "UTF-8"
          return text
        end
        reading.encoding = "ISO-8859-15"
        text = convert(bytes, "ISO-8859-15")
        c1?(text) ? windows(bytes, text, reading) : text
      end

      # Encodage imposé.
      private def self.decode_as(bytes : Bytes, given : String, wanted : String, reading : Reading) : String
        name = ENCODINGS[wanted]? || raise Failure.new("encoding_unknown", {"name" => given})
        reading.encoding = name
        return convert(bytes, name) unless name == "UTF-8"
        utf8!(bytes[0, 3]? == UTF8_BOM ? bytes[3..] : bytes)
      end

      # Lecture en Windows-1252 ; un octet que cet encodage ne définit pas
      # garde la lecture ISO 8859-15 (l'avertissement C1 le signale).
      private def self.windows(bytes : Bytes, latin : String, reading : Reading) : String
        text = String.new(bytes, "WINDOWS-1252")
        reading.encoding = "WINDOWS-1252"
        text
      rescue ArgumentError
        latin
      end

      # Caractères de contrôle C1 (U+0080 à U+009F) : signe d'un fichier
      # Windows-1252 lu dans un autre encodage.
      def self.c1?(text : String) : Bool
        text.each_char.any? { |char| 0x80 <= char.ord <= 0x9F }
      end

      private def self.utf8!(bytes : Bytes) : String
        text = String.new(bytes)
        raise Failure.new("invalid_utf8") unless text.valid_encoding?
        text
      end

      private def self.convert(bytes : Bytes, name : String) : String
        String.new(bytes, name)
      rescue ArgumentError
        raise Failure.new("unreadable_encoding", {"name" => name})
      end

      # --- Zones ---------------------------------------------------------------

      private def self.separator(header : String, strict : Bool) : Char?
        return '\t' if header.includes?('\t')
        return '|' if header.includes?('|')
        return ';' if !strict && header.includes?(';')
        nil
      end

      def self.split(line : String, separator : Char) : Array(String)
        line.split(separator).map do |value|
          value = value.strip
          value.size >= 2 && value.starts_with?('"') && value.ends_with?('"') ? value[1..-2].gsub("\"\"", "\"") : value
        end
      end

      # Position de chaque zone, sans égard à la casse ; `nil` (et un défaut
      # par zone manquante) s'il en manque.
      private def self.column_index(columns : Array(String), strict : Bool, reading : Reading) : Hash(String, Int32)?
        index = {} of String => Int32
        columns.each_with_index { |name, position| index[name.downcase] ||= position }
        missing = (strict ? STRICT : MINIMAL).reject { |name| index.has_key?(name.downcase) }
        unless (index.has_key?("debit") && index.has_key?("credit")) || (index.has_key?("montant") && index.has_key?("sens"))
          missing << "Debit/Credit"
        end
        missing.each { |name| reading.issue(1, name, "missing_column", {"column" => name}) }
        missing.empty? ? index : nil
      end

      # Zones d'une ligne, lues par nom.
      private struct Fields
        getter row : Int32
        getter problems = [] of {String, String, Hash(String, String)}

        def initialize(@fields : Array(String), @index : Hash(String, Int32), @row : Int32)
        end

        def [](name : String) : String
          @index[name.downcase]?.try { |position| @fields[position]? } || ""
        end

        def has?(name : String) : Bool
          @index.has_key?(name.downcase)
        end

        def presence(name : String) : String?
          self[name].presence
        end

        def problem(column : String, key : String, params = {} of String => String) : Nil
          @problems << {column, key, params}
        end

        def date(name : String) : Time?
          value = self[name]
          return if value.empty?
          found = FecReader.parse_date(value)
          problem(name, "unreadable_date", {"value" => value}) if found.nil?
          found
        end

        def amount(name : String) : BigDecimal?
          value = self[name]
          found = FecReader.parse_amount(value)
          problem(name, "unreadable_amount", {"value" => value}) if found.nil?
          found
        end

        def due_date : Time?
          DUE_DATES.each do |name|
            next unless has?(name)
            found = date(name)
            return found if found
          end
          nil
        end
      end

      # Montant d'une zone : virgule ou point décimal, blancs (insécables
      # compris) et `+` admis, `1.234,56` compris ; vide = zéro ; `nil` si
      # illisible.
      def self.parse_amount(text : String) : BigDecimal?
        value = text.strip.gsub(/[\s  ]/, "").lchop('+')
        return ZERO if value.empty?
        value = value.delete('.') if value.includes?(',') && value.includes?('.')
        value = value.tr(",", ".")
        return unless value.matches?(/\A-?\d+(\.\d+)?\z|\A-?\.\d+\z/)
        BigDecimal.new(value)
      rescue InvalidBigDecimalException
        nil
      end

      # Date `AAAAMMJJ` (`AAAA-MM-JJ` et `JJ/MM/AAAA` tolérées) ; `nil` si
      # illisible.
      def self.parse_date(text : String) : Time?
        value = text.strip
        year, month, day = case value
                           when /\A(\d{4})(\d{2})(\d{2})\z/, /\A(\d{4})-(\d{2})-(\d{2})\z/
                             {$1.to_i, $2.to_i, $3.to_i}
                           when /\A(\d{2})\/(\d{2})\/(\d{4})\z/
                             {$3.to_i, $2.to_i, $1.to_i}
                           else
                             return
                           end
        Time.utc(year, month, day)
      rescue ArgumentError
        nil
      end

      # --- Lignes --------------------------------------------------------------

      private def self.read_line(fields : Fields, reading : Reading) : Nil
        %w[JournalCode EcritureNum CompteNum EcritureDate].each do |name|
          fields.problem(name, "empty_field", {"column" => name}) if fields[name].empty?
        end
        date = fields.date("EcritureDate")
        valid_date = fields.date("ValidDate")
        letter_date = fields.date("DateLet")
        receipt_date = fields.date("PieceDate")
        due_date = fields.due_date
        raw_debit, raw_credit = amounts(fields)
        currency_amount = fields.presence("Montantdevise").try { fields.amount("Montantdevise") }
        problems = fields.problems
        problems.each { |(column, key, params)| reading.issue(fields.row, column, key, params) }
        return unless problems.empty? && date && raw_debit && raw_credit

        if raw_debit == raw_credit
          reading.zero_lines += 1
          return
        end
        reading.raw_debit += raw_debit
        reading.raw_credit += raw_credit
        net = raw_debit - raw_credit
        aux = fields.presence("CompAuxNum")
        line = Api::FecLineView.new(
          row: fields.row, account_number: fields["CompteNum"], account_label: fields["CompteLib"],
          aux_number: aux, aux_label: aux ? fields["CompAuxLib"] : nil, label: fields["EcritureLib"],
          debit: net > 0 ? net : ZERO, credit: net < 0 ? -net : ZERO, raw_debit: raw_debit, raw_credit: raw_credit,
          letter: fields.presence("EcritureLet"), letter_date: letter_date, valid_date: valid_date,
          currency_amount: currency_amount, currency_code: fields.presence("Idevise"),
        )
        store(fields, reading, date, receipt_date, due_date, line)
      end

      # Débit et crédit tels qu'écrits (`Debit` / `Credit`, ou `Montant` et
      # `Sens` : `D`, `C`, `+1`, `1`, `-1`).
      private def self.amounts(fields : Fields) : {BigDecimal?, BigDecimal?}
        return {fields.amount("Debit"), fields.amount("Credit")} if fields.has?("Debit")
        amount = fields.amount("Montant")
        direction = fields["Sens"].strip.upcase
        case direction
        when "D", "+1", "1", "DEBIT" then {amount, ZERO}
        when "C", "-1", "CREDIT"     then {ZERO, amount}
        else
          fields.problem("Sens", "unreadable_direction", {"value" => direction})
          {nil, nil}
        end
      end

      private def self.store(fields : Fields, reading : Reading, date : Time, receipt_date : Time?, due_date : Time?,
                             line : Api::FecLineView) : Nil
        key = {fields["JournalCode"], fields["EcritureNum"]}
        if position = reading.groups[key]?
          entry = reading.entries[position]
          if entry.date != date
            reading.issue(fields.row, "EcritureDate", "date_mismatch", {"entry" => entry.reference,
                                                                        "date" => date.to_s("%Y%m%d"), "expected" => entry.date.to_s("%Y%m%d")})
          end
          entry.lines << line
          if entry.due_date.nil? && due_date
            reading.entries[position] = entry.copy_with(due_date: due_date)
          end
          return
        end
        reading.groups[key] = reading.entries.size
        reading.entries << Api::FecEntryView.new(
          row: fields.row, journal_code: key[0], journal_label: fields["JournalLib"], number: key[1], date: date,
          receipt: fields["PieceRef"], receipt_date: receipt_date, label: fields["EcritureLib"], due_date: due_date,
          lines: [line],
        )
      end
    end
  end
end
