# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  # Sonde des traductions pendant la suite de specs (ADR-005 D7) : toute
  # recherche faite par le code (`I18n.t`, message d'une `FieldError`,
  # courriel, PDF, Factur-X, données initiales…), quelle que soit la langue
  # active, et toute erreur rendue par `Api::Result.failure`, même jamais
  # affichée, doit avoir sa clé en fr, en et nl, et chaque interpolation de
  # chaque langue doit recevoir un paramètre. Une recherche avec `default:`,
  # volontairement tolérante, n'est pas contrôlée. Les défauts sont
  # rapportés en fin de suite, qui échoue alors.
  #
  # L'interface a la même sonde pour elle, les extensions et la
  # distribution (`PartiduoUi::Translations::Probe`).
  module TranslationProbe
    @@texts : Hash(String, Hash(String, I18n::TranslationsHashValues))? = nil
    @@failures = {} of String => String
    @@lookups = 0

    def self.lookups : Int32
      @@lookups
    end

    # Valeur de chaque clé (feuille ou nœud), par langue.
    def self.texts : Hash(String, Hash(String, I18n::TranslationsHashValues))
      @@texts ||= begin
        values = Partiduo::LOCALES.to_h { |locale| {locale.to_s, {} of String => I18n::TranslationsHashValues} }
        I18n.config.loaders.each do |loader|
          loader.load.each do |locale, data|
            flatten(data, "", values[locale]) if data.is_a?(Hash) && values.has_key?(locale)
          end
        end
        values
      end
    end

    private def self.flatten(data : I18n::TranslationsHash, prefix : String,
                             into : Hash(String, I18n::TranslationsHashValues)) : Nil
      data.each do |name, value|
        key = prefix.empty? ? name : "#{prefix}.#{name}"
        into[key] = value
        flatten(value, key, into) if value.is_a?(Hash)
      end
    end

    # Recherche faite par `I18n::Catalog#translate`.
    def self.lookup(key : String | Symbol, params, count, scope, default, kwargs) : Nil
      return unless default.nil?
      @@lookups += 1
      full = case scope
             when Array then (scope.map(&.to_s) << key.to_s).join('.')
             when Nil   then key.to_s
             else            "#{scope}.#{key}"
             end
      names = Set(String).new
      params.try &.each { |name, _| names << name.to_s }
      kwargs.each { |name, _| names << name.to_s }
      names << "count" unless count.nil?
      check(full, names, !count.nil?)
    end

    # Erreurs d'un échec du contrat.
    def self.field_errors(errors : Array(Api::FieldError)) : Nil
      errors.each do |error|
        check(error.key, error.params.keys.to_set, !error.params["count"]?.try(&.to_i64?).nil?)
      end
    end

    private def self.check(key : String, names : Set(String), plural : Bool) : Nil
      Partiduo::LOCALES.each do |locale|
        problem = problem(locale.to_s, key, names, plural)
        next if problem.nil? || @@failures.has_key?(problem)
        @@failures[problem] = origin
      end
    end

    # Défaut d'une clé dans une langue : absente, sous-arbre demandé sans
    # compte, interpolation sans paramètre.
    def self.problem(locale : String, key : String, names : Set(String), plural : Bool) : String?
      catalog = texts[locale]
      return "#{locale}.#{key} absente" unless catalog.has_key?(key)
      value = catalog[key]
      strings = case value
                when Hash
                  return "#{locale}.#{key} est un sous-arbre, demandé sans compte" unless plural
                  forms = [] of String
                  value.each_value { |form| forms << form if form.is_a?(String) }
                  forms
                when Array then [value.join("\n")]
                else            [value.to_s]
                end
      unresolved = strings.flat_map(&.scan(/%\{(\w+)\}/).map(&.[1])).uniq!.reject { |name| names.includes?(name) }
      "#{locale}.#{key} : #{unresolved.map { |name| "%{#{name}}" }.join(" ")} sans paramètre" unless unresolved.empty?
    end

    # Premier appelant hors de crystal-i18n, du contrat d'erreurs et de
    # cette sonde.
    private def self.origin : String
      caller.find do |frame|
        !frame.includes?("/i18n/") && !frame.includes?("translation_probe.cr") &&
          !frame.includes?("api/result.cr") && !frame.includes?("api/field_error.cr") &&
          (frame.includes?("/src/") || frame.includes?("/spec/"))
      end.try(&.strip) || "?"
    end

    def self.report : Array(String)
      @@failures.map { |problem, where| "#{problem} (#{where})" }.sort!
    end
  end
end

class I18n::Catalog
  def translate(key : String | Symbol, params : Hash | NamedTuple? = nil, count : Float | Int? = nil,
                scope : Array(String | Symbol) | String | Symbol? = nil, default = nil, **kwargs) : String
    Partiduo::TranslationProbe.lookup(key, params, count, scope, default, kwargs)
    previous_def
  end
end

struct Partiduo::Api::Result(T)
  def self.failure(errors : Array(Partiduo::Api::FieldError)) : self
    Partiduo::TranslationProbe.field_errors(errors)
    previous_def
  end
end

# Rapport après le résumé des specs (crochet de sortie posé en fin de
# suite), pour ne pas le masquer.
Spec.after_suite do
  at_exit do
    failures = Partiduo::TranslationProbe.report
    next if failures.empty?
    STDERR.puts "\nTraductions absentes ou incomplètes relevées pendant la suite " \
                "(#{failures.size}, spec/support/translation_probe.cr) :"
    failures.each { |failure| STDERR.puts "  #{failure}" }
    exit 1
  end
end
