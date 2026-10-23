# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "yaml"

private INTERPOLATION = /%\{[^}]*\}/

# Feuilles d'un arbre de locales : clé complète → texte.
private def leaves(node : YAML::Any, prefix : String = "", into = {} of String => String) : Hash(String, String)
  if hash = node.as_h?
    hash.each { |key, value| leaves(value, prefix.empty? ? key.to_s : "#{prefix}.#{key}", into) }
  else
    into[prefix] = node.as_a?.try(&.map(&.to_s).join("\n")) || node.to_s
  end
  into
end

# Clés (feuilles et nœuds : pluriels, sous-arbres) d'une langue, toutes
# applications chargées.
private def catalog(locale : String) : Set(String)
  keys = Set(String).new
  I18n.config.loaders.each do |loader|
    data = loader.load[locale]?
    collect(data, "", keys) if data.is_a?(Hash)
  end
  keys
end

private def collect(data : I18n::TranslationsHash, prefix : String, into : Set(String)) : Nil
  data.each do |name, value|
    key = prefix.empty? ? name : "#{prefix}.#{name}"
    into << key
    collect(value, key, into) if value.is_a?(Hash)
  end
end

private def translated_everywhere(keys : Enumerable(String)) : Array(String)
  catalogs = Partiduo::LOCALES.to_h { |locale| {locale.to_s, catalog(locale.to_s)} }
  keys.flat_map { |key| catalogs.compact_map { |locale, known| "#{locale}:#{key}" unless known.includes?(key) } }.uniq!.sort!
end

describe "Traductions (ADR-005 D7)" do
  it "fournit les mêmes clés, aux mêmes interpolations, dans chaque langue livrée et chaque application" do
    src = File.expand_path("../../src", __DIR__)
    failures = [] of String
    Dir.glob(File.join(src, "*", "locales")).sort.each do |dir|
      values = Partiduo::LOCALES.to_h do |locale|
        path = File.join(dir, "#{locale}.yml")
        File.exists?(path).should be_true
        {locale.to_s, leaves(YAML.parse(File.read(path))[locale.to_s])}
      end
      reference = values["fr"]
      Partiduo::LOCALES.reject("fr").each do |locale|
        other = values[locale]
        (reference.keys - other.keys).each { |key| failures << "#{dir} : #{locale} n'a pas #{key}" }
        (other.keys - reference.keys).each { |key| failures << "#{dir} : #{locale} a #{key}, absente en fr" }
        (reference.keys & other.keys).each do |key|
          expected = reference[key].scan(INTERPOLATION).map(&.[0]).to_set
          next if other[key].scan(INTERPOLATION).map(&.[0]).to_set == expected
          failures << "#{dir} : #{locale}.#{key} n'interpole pas #{expected.to_a.sort.join(" ")}"
        end
      end
    end
    failures.should eq([] of String)
  end

  it "traduit dans chaque langue livrée toute clé passée à I18n.t" do
    root = File.expand_path("../..", __DIR__)
    cited = Dir.glob(File.join(root, "src", "**", "*.cr")).flat_map do |path|
      File.read_lines(path).reject(&.lstrip.starts_with?('#')).flat_map do |line|
        line.scan(/I18n\.t(?:ranslate)?!?\(\s*"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"/).map(&.[1])
      end
    end
    cited.size.should be > 50
    translated_everywhere(cited).should eq([] of String)
  end

  it "traduit le nom, les permissions et les menus de chaque pièce du registre" do
    keys = Partiduo::Modules.manifests.values.flat_map do |manifest|
      [manifest.name] + manifest.permission_entries.map(&.label) + manifest.menus.map(&.label)
    end
    translated_everywhere(keys).should eq([] of String)
  end
end
