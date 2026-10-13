# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Contrat du module Comptabilité — lectures ajoutées par les amendements
    # du 13 octobre 2026 (ADR-003) : une ligne par son identifiant
    # (A-AMO-4), les écritures ouvertes de toutes les fiches d'une nature
    # (A-SEPA-1), les sommes de lignes par critère (A-REP-3), les totaux par
    # code de TVA (A-REP-5), le solde d'un compte à une date (A-PER-1).
    # Calculs faits par PostgreSQL, dans les journaux visibles de l'acteur.
    # Types dans `sum_types.cr` ; référence : `doc/api/accounting-reference.adoc`
    # et `doc/api/accounting-reports.adoc`.
    module Accounting
      # Une ligne d'écriture par son identifiant (A-AMO-4), avec
      # `entry_id`. `NotFound` si elle n'existe pas ou si son journal n'est
      # pas visible de l'acteur.
      def self.entry_line(actor : Actor, id : Int64) : EntryLineView
        Guard.authorize!(actor, "accounting.entry.read", module_code: MODULE_CODE)
        line = Partiduo::Accounting::EntryLine.filter(id: id).first || raise NotFound.new("entry_line", id)
        entry = Partiduo::Accounting::Entry.filter(id: line.entry_id).first || raise NotFound.new("entry_line", id)
        raise NotFound.new("entry_line", id) unless readable_ledger_ids(actor).includes?(entry.ledger_id.as(Int).to_i64)
        entry_views([entry]).first.lines.find(&.id.==(id)) || raise NotFound.new("entry_line", id)
      end

      # Solde débit − crédit d'un compte au jour `as_of` (inclus ; date du
      # jour par défaut), sans charger ses lignes (A-PER-1) : mêmes lignes
      # que le solde final d'`account_statement` (journaux visibles, tous
      # exercices). `prefix` : les comptes qui commencent par ce numéro.
      # `NotFound` si aucun compte ne répond.
      def self.account_balance(actor : Actor, number : String, as_of : Time? = nil, prefix : Bool = false) : BigDecimal
        Guard.authorize!(actor, "accounting.entry.read", module_code: MODULE_CODE)
        normalized = Partiduo::Accounting::Chart.normalize(number.strip)
        accounts = prefix ? Partiduo::Accounting::Account.filter(number__startswith: normalized) : Partiduo::Accounting::Account.filter(number: normalized)
        raise NotFound.new("account", normalized) if normalized.empty? || !accounts.exists?
        ledger_ids = readable_ledger_ids(actor)
        return BigDecimal.new(0) if ledger_ids.empty?
        day = Partiduo::Accounting::Posting.day(as_of || Partiduo::Config.today)
        condition = prefix ? "a.number LIKE $1" : "a.number = $1"
        sql = "SELECT COALESCE(sum(CASE WHEN x.side = 'debit' THEN x.amount ELSE -x.amount END), 0) " \
              "FROM accounting_entry_line x JOIN accounting_entry e ON e.id = x.entry_id " \
              "JOIN accounting_account a ON a.id = x.account_id " \
              "WHERE #{condition} AND e.date <= $2::date AND e.ledger_id IN (#{ledger_ids.join(", ")})"
        Marten::DB::Connection.default.open do |db|
          db.query_one(sql, args: [(prefix ? "#{normalized}%" : normalized), day] of ::DB::Any, as: BigDecimal)
        end
      end

      # Lignes ouvertes de toutes les fiches de la nature `kind`
      # (`customer`, `supplier`…) en deux requêtes (A-SEPA-1) : lignes de
      # tiers non lettrées, et avec `include_partial` celles d'un lettrage
      # partiel. `as_of` (date du jour par défaut) : date de référence de
      # l'échu et date d'arrêt (écritures datées au plus tard ce jour-là ; un
      # lettrage n'est équilibré que par des lignes antérieures, comme
      # `aged_balance`). Triées par fiche, date, écriture, position.
      def self.open_items(actor : Actor, kind : String, as_of : Time? = nil,
                          include_partial : Bool = false) : Array(PartyOpenItemView)
        Guard.authorize!(actor, "accounting.entry.read", module_code: MODULE_CODE)
        cards = Partiduo::Accounting::ReportData.cards([kind])
        Partiduo::Accounting::OpenItems.list(cards, readable_ledger_ids(actor),
          Partiduo::Accounting::Posting.day(as_of || Partiduo::Config.today), include_partial)
      end

      # Sommes par compte des lignes retenues par `query` (A-REP-3) : poste
      # avec contrepartie, chiffre d'affaires d'une fiche, période selon la
      # date d'opération, de paiement ou d'échéance. Comptes sans ligne
      # absents ; triés par numéro.
      def self.line_sums(actor : Actor, query : LineSumQuery) : Array(LineSumView)
        Guard.authorize!(actor, REPORT_READ, module_code: MODULE_CODE)
        ledger_ids = Partiduo::Accounting::ReportData.ledgers(readable_ledger_ids(actor), query.ledger_ids, query.ledger_kinds)
        Partiduo::Accounting::LineSums.line_sums(query, ledger_ids)
      end

      # Base et TVA par code de taux, compte et type de journal (A-REP-5) :
      # lignes de rôle `base` ou `tax` portant un taux, dans la période
      # (selon `date_basis`). Triés par code de taux, type de journal, compte.
      def self.vat_totals(actor : Actor, query : VatTotalsQuery = VatTotalsQuery.new) : Array(VatTotalView)
        Guard.authorize!(actor, REPORT_READ, module_code: MODULE_CODE)
        ledger_ids = Partiduo::Accounting::ReportData.ledgers(readable_ledger_ids(actor), query.ledger_ids, query.ledger_kinds)
        Partiduo::Accounting::LineSums.vat_totals(query, ledger_ids)
      end
    end
  end
end
