# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Cards
    # Import de fiches depuis un fichier CSV, héritier de l'import de fiches
    # de l'application d'origine (D-OUT-003) : une catégorie, des colonnes
    # associées aux champs de la fiche, une ligne par fiche. Chaque ligne
    # passe par les commandes du contrat (`create_card`, `update_card`) :
    # mêmes contrôles, même événement `card.saved` qu'à la saisie. Service
    # interne : l'import passe par `Partiduo::Api::Cards`.
    module CardImport
      alias FieldError = Partiduo::Api::FieldError
      alias Field = Partiduo::Api::Core::ImportFieldView
      alias Row = Partiduo::Api::Core::ImportRowView
      alias Action = Partiduo::Api::Core::ImportAction
      alias CsvImport = Partiduo::Core::CsvImport

      ADDRESS_FIELDS = %w[line1 line2 postcode city country_code]
      PARTY_FIELDS   = %w[vat_number siren siret routing_id iban bic email phone contact_name]
      ITEM_FIELDS    = %w[unit_code sale_price purchase_price vat_rate]
      PERSON_FIELDS  = %w[supplier_nature last_name first_names birth_date]

      # Champs proposés pour une catégorie : ceux de sa nature, ses attributs
      # propres (`extra.<clé>`), et le compte comptable si la Comptabilité
      # suit les fiches (`account`, à la création seulement).
      def self.fields(category : Category) : Array(Field)
        kind = category.kind!
        keys = [] of String
        keys.concat(%w[code description enabled])
        if kind == "item"
          keys.concat(ITEM_FIELDS)
        else
          keys.concat(PARTY_FIELDS)
          keys.concat(ADDRESS_FIELDS.map { |field| "address.#{field}" })
          keys << "customer_nature" if kind == "customer"
          keys.concat(PERSON_FIELDS) if kind == "supplier"
        end
        # Un fournisseur personne physique peut n'avoir que nom et prénoms.
        list = [Field.new("name", label_key("name"), required: kind != "supplier")]
        list.concat(keys.map { |key| Field.new(key, label_key(key)) })
        CategoryAttribute.filter(category_id: category.id).order(:position, :id).each do |attribute|
          list << Field.new("extra.#{attribute.key!}", "", required: attribute.required == true, label: attribute.label!)
        end
        list << Field.new("account", label_key("account")) if accounting?
        list
      end

      def self.label_key(key : String) : String
        "cards.import.fields.#{key.tr(".", "_")}"
      end

      # La Comptabilité rattache-t-elle un compte aux fiches neuves ?
      def self.accounting? : Bool
        Partiduo::Events.subscribers("card.saved").includes?("ACCOUNTING")
      end

      # Lit et traite le fichier : une ligne après l'autre, dans la
      # transaction de l'appelant (à blanc pour l'aperçu).
      def self.run(actor : Partiduo::Api::Actor, category : Category,
                   source : Partiduo::Api::Core::ImportSource) : Partiduo::Api::Core::ImportView
        fields = fields(category)
        records, errors = CsvImport.read(source)
        columns, records, header = CsvImport.associate(records, fields, source.columns, ["name"])
        errors.concat(CsvImport.column_errors(columns, fields)) if errors.empty?
        rows = [] of Row
        if errors.empty?
          attributes = CategoryAttribute.filter(category_id: category.id).to_a.to_h { |attribute| {attribute.key!, attribute} }
          rows = records.map do |record|
            row(actor, category, attributes, record, CsvImport.values(record, columns), source.update_existing)
          end
        end
        Partiduo::Api::Core::ImportView.new(fields, columns, header, rows, errors)
      end

      private def self.row(actor : Partiduo::Api::Actor, category : Category, attributes : Hash(String, CategoryAttribute),
                           record : CsvImport::Record, values : Hash(String, String), update_existing : Bool) : Row
        values = values.transform_values { |value| CsvImport.unprotect(value) }
        code = values["code"]?.presence
        existing = code.try { |value| Card.filter(code: QuickCode.format(value)).first }
        reference = existing.try(&.code) || code.try { |value| QuickCode.format(value) } || ""
        errors = [] of FieldError
        if existing
          return refused(record, reference, "cards.errors.import.code_exists", {"code" => reference}) unless update_existing
          if existing.category_id != category.id
            return refused(record, reference, "cards.errors.import.other_category", {"code" => reference})
          end
          if values["account"]?.presence
            return refused(record, reference, "cards.errors.import.account_on_update", {"code" => reference})
          end
          view = Partiduo::Api::Cards.card(actor, existing.id!.to_i64)
          input = merge(view.to_input, values, attributes, errors)
          return Row.new(record.line, record.cells, Action::Refused, reference, errors) unless errors.empty?
          result = Partiduo::Api::Cards.update_card(actor, view.id, input)
          return outcome(record, reference, result, Action::Update)
        end

        account = values["account"]?.presence
        if account && !actor.can?("accounting.account.write")
          return refused(record, reference, "cards.errors.import.account_forbidden")
        end
        base = Partiduo::Api::Cards::CardInput.new(category_id: category.id!.to_i64, name: "")
        input = merge(base, values, attributes, errors)
        return Row.new(record.line, record.cells, Action::Refused, reference, errors) unless errors.empty?
        result = Partiduo::Api::Cards.create_card(actor, input, account)
        outcome(record, reference, result, Action::Create)
      end

      private def self.outcome(record : CsvImport::Record, reference : String,
                               result : Partiduo::Api::Result(Partiduo::Api::Cards::CardView), action : Action) : Row
        if view = result.value?
          Row.new(record.line, record.cells, action, view.code)
        else
          Row.new(record.line, record.cells, Action::Refused, reference, result.errors.map { |error| column_error(error) })
        end
      end

      private def self.refused(record : CsvImport::Record, reference : String, key : String,
                               params = {} of String => String) : Row
        Row.new(record.line, record.cells, Action::Refused, reference, [FieldError.base(key, params)])
      end

      # Erreur du contrat rapportée au champ importé (`vat_rate_id` →
      # `vat_rate`).
      private def self.column_error(error : FieldError) : FieldError
        error.field == "vat_rate_id" ? FieldError.new("vat_rate", error.key, error.params) : error
      end

      # Saisie de la fiche : `input` complétée des cellules non vides (une
      # cellule vide garde la valeur de la fiche mise à jour, ou la valeur
      # par défaut à la création). Fournisseur sans nature mais avec un nom
      # ou des prénoms de personne : personne physique (`individual`).
      private def self.merge(input : Partiduo::Api::Cards::CardInput, values : Hash(String, String),
                             attributes : Hash(String, CategoryAttribute),
                             errors : Array(FieldError)) : Partiduo::Api::Cards::CardInput
        given = values.reject { |_, value| value.empty? }
        input.copy_with(
          name: pick(given, "name", input.name).to_s,
          code: pick(given, "code", input.code),
          description: pick(given, "description", input.description),
          enabled: converted(given, "enabled", input.enabled) { |value| boolean("enabled", value, errors) },
          vat_number: pick(given, "vat_number", input.vat_number),
          siren: pick(given, "siren", input.siren),
          siret: pick(given, "siret", input.siret),
          routing_id: pick(given, "routing_id", input.routing_id),
          iban: pick(given, "iban", input.iban),
          bic: pick(given, "bic", input.bic),
          email: pick(given, "email", input.email),
          phone: pick(given, "phone", input.phone),
          contact_name: pick(given, "contact_name", input.contact_name),
          address: address(input.address, given),
          unit_code: pick(given, "unit_code", input.unit_code),
          sale_price: converted(given, "sale_price", input.sale_price) { |value| decimal("sale_price", value, errors) },
          purchase_price: converted(given, "purchase_price", input.purchase_price) { |value| decimal("purchase_price", value, errors) },
          vat_rate_id: converted(given, "vat_rate", input.vat_rate_id) { |value| vat_rate(value, errors) },
          extra: extra(input.extra, given, attributes, errors),
          customer_nature: converted(given, "customer_nature", input.customer_nature) { |value| nature("customer_nature", value) },
          supplier_nature: supplier_nature(input, given),
          last_name: pick(given, "last_name", input.last_name),
          first_names: pick(given, "first_names", input.first_names),
          birth_date: converted(given, "birth_date", input.birth_date) { |value| date("birth_date", value, errors) },
        )
      end

      private def self.pick(given : Hash(String, String), key : String, fallback : String?) : String?
        given.fetch(key, fallback)
      end

      # Valeur convertie d'une cellule non vide ; `fallback` sans cellule ou
      # si la conversion échoue (l'erreur est alors notée par le bloc).
      private def self.converted(given : Hash(String, String), key : String, fallback : T, &) forall T
        text = given[key]?
        return fallback unless text
        value = yield text
        value.nil? ? fallback : value
      end

      private def self.supplier_nature(input : Partiduo::Api::Cards::CardInput, given : Hash(String, String)) : String?
        if text = given["supplier_nature"]?
          return nature("supplier_nature", text)
        end
        person = given.has_key?("last_name") || given.has_key?("first_names")
        return "individual" if person && input.supplier_nature.nil?
        input.supplier_nature
      end

      private def self.extra(current : Hash(String, JSON::Any), given : Hash(String, String),
                             attributes : Hash(String, CategoryAttribute), errors : Array(FieldError)) : Hash(String, JSON::Any)
        extra = current.dup
        attributes.each do |key, attribute|
          text = given["extra.#{key}"]?
          next unless text
          extra_value(attribute, text, errors).try { |value| extra[key] = value }
        end
        extra
      end

      private def self.address(current : Partiduo::Api::Cards::AddressInput?,
                               given : Hash(String, String)) : Partiduo::Api::Cards::AddressInput?
        return current unless ADDRESS_FIELDS.any? { |field| given.has_key?("address.#{field}") }
        base = current || Partiduo::Api::Cards::AddressInput.new
        base.copy_with(
          line1: given["address.line1"]? || base.line1,
          line2: given["address.line2"]? || base.line2,
          postcode: given["address.postcode"]? || base.postcode,
          city: given["address.city"]? || base.city,
          country_code: given["address.country_code"]?.try(&.upcase) || base.country_code,
        )
      end

      private def self.extra_value(attribute : CategoryAttribute, value : String, errors : Array(FieldError)) : JSON::Any?
        key = "extra.#{attribute.key!}"
        case attribute.value_type
        when "number"
          decimal(key, value, errors).try { |number| JSON::Any.new(number.to_s) }
        when "date"
          date(key, value, errors).try { |day| JSON::Any.new(day.to_s("%Y-%m-%d")) }
        when "boolean"
          flag = boolean(key, value, errors)
          flag.nil? ? nil : JSON::Any.new(flag)
        when "card"
          card = Card.filter(code: QuickCode.format(value)).first
          if card.nil?
            errors << FieldError.new(key, "cards.errors.import.card_unknown", {"code" => value})
            return
          end
          JSON::Any.new(card.id!.to_i64)
        else
          JSON::Any.new(value)
        end
      end

      private def self.decimal(key : String, value : String, errors : Array(FieldError)) : BigDecimal?
        number = CsvImport.decimal(value)
        errors << FieldError.new(key, "core.errors.import.decimal", {"value" => value}) unless number
        number
      end

      private def self.date(key : String, value : String, errors : Array(FieldError)) : Time?
        day = CsvImport.date(value)
        errors << FieldError.new(key, "core.errors.import.date", {"value" => value}) unless day
        day
      end

      private def self.boolean(key : String, value : String, errors : Array(FieldError)) : Bool?
        flag = CsvImport.boolean(value)
        errors << FieldError.new(key, "core.errors.import.boolean", {"value" => value}) if flag.nil?
        flag
      end

      private def self.vat_rate(value : String, errors : Array(FieldError)) : Int64?
        rate = Partiduo::Vat::Rate.filter(code: value.strip.upcase).first || Partiduo::Vat::Rate.filter(code: value.strip).first
        errors << FieldError.new("vat_rate", "cards.errors.import.vat_rate_unknown", {"code" => value}) unless rate
        rate.try(&.id!.to_i64)
      end

      # Nature saisie par son code (`individual`) ou son libellé, dans
      # l'une des langues ; inconnue, elle est passée telle quelle au
      # contrat, qui la refuse.
      private def self.nature(key : String, value : String) : String
        scope = key == "customer_nature" ? "natures" : "supplier_natures"
        codes = key == "customer_nature" ? CardRules::CUSTOMER_NATURES : CardRules::SUPPLIER_NATURES
        wanted = value.strip.downcase
        codes.each do |code|
          return code if code == wanted
          Partiduo::LOCALES.each do |locale|
            label = I18n.with_locale(locale) { I18n.t("cards.#{scope}.#{code}") }
            return code if label.downcase == wanted
          end
        end
        value.strip
      end

      # --- Export ----------------------------------------------------------------

      # Fiches d'une catégorie au format de l'import (en-tête : libellés des
      # champs dans la langue courante ; sans le compte comptable, que le
      # socle ignore).
      def self.csv(category : Category, views : Array(Partiduo::Api::Cards::CardView)) : Bytes
        fields = fields(category).reject(&.key.==("account"))
        CSV.build(separator: ';') do |csv|
          csv.row fields.map { |field| Partiduo::Core::TableOutput.csv_text(field.title) }
          views.each do |view|
            csv.row(fields.map { |field| Partiduo::Core::TableOutput.csv_text(export_value(view, field.key)) })
          end
        end.to_slice
      end

      private def self.export_value(view : Partiduo::Api::Cards::CardView, key : String) : String
        if key.starts_with?("extra.")
          raw = view.extra[key.lchop("extra.")]?
          return "" unless raw
          return raw.as_bool ? "1" : "0" unless raw.as_bool?.nil?
          if id = raw.as_i64?
            return Card.filter(id: id).first.try(&.code).to_s
          end
          return raw.as_s? || raw.to_json
        end
        EXPORTS[key]?.try(&.call(view)) || ""
      end

      private alias View = Partiduo::Api::Cards::CardView

      # Valeur exportée de chaque champ (mêmes clés que `fields`).
      EXPORTS = {
        "name"                 => ->(view : View) { view.name },
        "code"                 => ->(view : View) { view.code },
        "description"          => ->(view : View) { view.description },
        "enabled"              => ->(view : View) { view.enabled ? "1" : "0" },
        "vat_number"           => ->(view : View) { view.vat_number },
        "siren"                => ->(view : View) { view.siren },
        "siret"                => ->(view : View) { view.siret },
        "routing_id"           => ->(view : View) { view.routing_id },
        "iban"                 => ->(view : View) { view.iban },
        "bic"                  => ->(view : View) { view.bic },
        "email"                => ->(view : View) { view.email },
        "phone"                => ->(view : View) { view.phone },
        "contact_name"         => ->(view : View) { view.contact_name },
        "address.line1"        => ->(view : View) { view.address.try(&.line1).to_s },
        "address.line2"        => ->(view : View) { view.address.try(&.line2).to_s },
        "address.postcode"     => ->(view : View) { view.address.try(&.postcode).to_s },
        "address.city"         => ->(view : View) { view.address.try(&.city).to_s },
        "address.country_code" => ->(view : View) { view.address.try(&.country_code).to_s },
        "unit_code"            => ->(view : View) { view.unit_code },
        "sale_price"           => ->(view : View) { view.sale_price.try { |value| CardImport.plain(value) }.to_s },
        "purchase_price"       => ->(view : View) { view.purchase_price.try { |value| CardImport.plain(value) }.to_s },
        "vat_rate"             => ->(view : View) { view.vat_rate_code.to_s },
        "customer_nature"      => ->(view : View) { view.customer_nature },
        "supplier_nature"      => ->(view : View) { view.supplier_nature },
        "last_name"            => ->(view : View) { view.last_name },
        "first_names"          => ->(view : View) { view.first_names },
        "birth_date"           => ->(view : View) { view.birth_date.try(&.to_s("%Y-%m-%d")).to_s },
      }

      # Décimal sans zéros inutiles (`12.5`, `3`).
      def self.plain(value : BigDecimal) : String
        text = value.to_s
        text.includes?('.') ? text.rstrip('0').rstrip('.') : text
      end
    end
  end
end
