# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    module Accounting
      # Charge le plan comptable (PCMN belge ou PCG français, repris des
      # modèles d'origine), les comptes par défaut, le compte de base des catégories de
      # fiches par défaut du socle et les quatre journaux (achats,
      # ventes, financier, opérations diverses) du régime, noms des journaux
      # dans `locale`. Appelé par `partiduo-provision` (chargeur
      # `ACCOUNTING.reference_data`) ; refusé si le plan n'est pas vide.
      #
      # `chart` : plan de base du type de dossier (`InitialData::Kind#chart`) ;
      # `household` charge le plan réduit d'un foyer (ADR-011 A3) — trésorerie,
      # placements, biens, dettes, catégories de recettes et de dépenses,
      # libellés dans `locale` —, un journal financier et un journal
      # d'opérations diverses, sans compte de TVA.
      def self.load_initial_data(actor : Actor, regime : String, locale : String = "fr",
                                 chart : String = InitialData::COMPANY) : Result(InitialDataView)
        Guard.authorize!(actor, "accounting.account.write", module_code: MODULE_CODE)
        Guard.authorize!(actor, "accounting.ledger.write", module_code: MODULE_CODE)
        Transaction.run do
          unless Partiduo::Accounting::ReferenceData.regimes.includes?(regime)
            next Result(InitialDataView).failure(FieldError.new("regime", "accounting.errors.initial_data.regime.invalid"))
          end
          unless Partiduo::Accounting::ReferenceData.charts.includes?(chart)
            next Result(InitialDataView).failure(FieldError.new("chart", "accounting.errors.initial_data.chart.invalid"))
          end
          if Partiduo::Accounting::Account.all.exists? || Partiduo::Accounting::Ledger.all.exists?
            next Result(InitialDataView).failure(FieldError.base("accounting.errors.initial_data.not_empty"))
          end
          Result(InitialDataView).success(Partiduo::Accounting::ReferenceData.load(actor, regime, locale, chart))
        end
      end
    end
  end
end
