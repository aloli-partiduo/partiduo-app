# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    module Liberal
      # Immobilisations de la 2035 fournies par une extension (A-AMO-3) :
      # tableau des immobilisations et des amortissements de l'année
      # (2035-B : base, amortissements antérieurs, dotation), cessions et
      # plus ou moins-values (court et long terme), montants en devise de
      # tenue. `label_key` : clé i18n du nom de la source, citée par
      # l'édition de contrôle.
      record AssetSourceView,
        rows : Array(DepreciationRowView),
        disposals : Array(DisposalResultView),
        label_key : String

      # Source enregistrée : pièce du registre et bloc qui rend, pour une
      # année, les immobilisations qu'elle tient (`nil` si elle n'en tient
      # pas pour cette année, la 2035 lit alors le registre du module).
      record AssetSource, code : String, block : Proc(Actor, Int32, AssetSourceView?)

      @@asset_sources = [] of AssetSource

      # Déclare une source d'immobilisations (A-AMO-3) : un BNC qui tient
      # ses immobilisations dans une extension (amortissements dégressifs,
      # composants, cessions) voit sa 2035 préparée avec elles au lieu du
      # registre linéaire du module. Le bloc reçoit l'acteur système et
      # l'année ; il n'est appelé que si la pièce `code` est active.
      #
      # ```
      # Partiduo::Api::Liberal.register_asset_source("AMORTIS") do |actor, year|
      #   Amortis::Api.liberal_assets(actor, year)
      # end
      # ```
      def self.register_asset_source(code : String, &block : Actor, Int32 -> AssetSourceView?) : AssetSource
        unless code.matches?(/\A[A-Z][A-Z0-9_]*\z/)
          raise ArgumentError.new("code de pièce invalide (majuscules, chiffres, _) : #{code}")
        end
        raise ArgumentError.new("source d'immobilisations déjà déclarée : #{code}") if @@asset_sources.any?(&.code.==(code))
        source = AssetSource.new(code, block)
        @@asset_sources << source
        source
      end

      # Specs : retire une source déclarée par un exemple.
      def self.unregister_asset_source(code : String) : Nil
        @@asset_sources.reject!(&.code.==(code))
      end

      # Sources déclarées, actives ou non.
      def self.asset_sources : Array(AssetSource)
        @@asset_sources.dup
      end

      # Immobilisations de la 2035 de l'année : celles de la première source
      # active qui en tient pour cette année, avec son code ; `nil` sinon
      # (registre du module). Interne à la préparation de la 2035.
      def self.asset_source_for(year : Int32) : {String, AssetSourceView}?
        @@asset_sources.each do |source|
          next unless Partiduo::Modules.active?(source.code)
          view = source.block.call(Actor.system, year)
          return {source.code, view} if view
        end
        nil
      end
    end
  end
end
