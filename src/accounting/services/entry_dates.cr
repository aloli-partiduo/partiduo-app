# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Date de paiement ou d'échéance d'une écriture (A-REP-6), en SQL, pour
    # les recherches et les sommes qui situent les écritures `e` dans une
    # période. Service interne.
    #
    # Une écriture est *payée* quand elle porte au moins une ligne de tiers
    # (ligne d'une fiche qui n'est ni une banque ni un article), que
    # *toutes* ses lignes de tiers sont lettrées et que chacun de ces
    # lettrages est équilibré. Sa date de paiement est la plus récente des
    # écritures de ces lettrages, elle comprise : pour une facture, la date
    # de son dernier règlement ; pour un règlement, la sienne (ou celle
    # d'une facture postérieure). Une écriture de tiers dont une ligne
    # reste ouverte (ou en lettrage partiel) est *non payée* ; une écriture
    # sans ligne de tiers n'est ni l'une ni l'autre.
    module EntryDates
      alias Basis = Partiduo::Api::Accounting::DateBasis

      # Jointure qui calcule, pour chaque écriture `e`, `pay.paid_on` (date
      # de paiement, `NULL` si non payée) et `pay.party` (porte une ligne de
      # tiers).
      PAYMENT_JOIN = <<-SQL
        LEFT JOIN LATERAL (
          SELECT CASE WHEN count(*) > 0 AND bool_and(COALESCE(m.balanced, false))
                      THEN GREATEST(e.date, max(m.last_date)) END AS paid_on,
                 count(*) > 0 AS party
          FROM accounting_entry_line p
          JOIN cards_card pc ON pc.id = p.card_id
          JOIN cards_category pg ON pg.id = pc.category_id
          LEFT JOIN LATERAL (
            SELECT sum(CASE WHEN y.side = 'debit' THEN y.amount ELSE -y.amount END) = 0 AS balanced,
                   max(f.date) AS last_date
            FROM accounting_entry_line y
            JOIN accounting_entry f ON f.id = y.entry_id
            WHERE y.matching_id = p.matching_id
          ) m ON p.matching_id IS NOT NULL
          WHERE p.entry_id = e.id AND pg.kind NOT IN ('bank', 'item')
        ) pay ON true
        SQL

      # Expression SQL de la date retenue pour l'écriture `e`.
      def self.expression(basis : Basis) : String
        case basis
        in .operation? then "e.date"
        in .due?       then "COALESCE(e.due_date, e.date)"
        in .payment?   then "pay.paid_on"
        end
      end

      # La jointure de paiement est-elle nécessaire ?
      def self.join?(basis : Basis, paid : Bool?) : Bool
        basis.payment? || !paid.nil?
      end

      # Jointure à ajouter après `accounting_entry e`, ou chaîne vide.
      def self.join(basis : Basis, paid : Bool?) : String
        join?(basis, paid) ? PAYMENT_JOIN : ""
      end

      # Condition du filtre « payé / non payé », ou `nil`.
      def self.paid_clause(paid : Bool?) : String?
        case paid
        when true  then "pay.paid_on IS NOT NULL"
        when false then "pay.party AND pay.paid_on IS NULL"
        end
      end

      # Conditions de période et de paiement sur `e`, paramètres ajoutés à
      # `args`. Une écriture non payée n'a pas de date de paiement : avec
      # `Payment`, elle est écartée même sans borne.
      def self.clauses(args : Array(::DB::Any), basis : Basis, paid : Bool?, from : Time?, to : Time?) : Array(String)
        param = ->(value : ::DB::Any) { args << value; "$#{args.size}" }
        date = expression(basis)
        clauses = [] of String
        from.try { |day| clauses << "#{date} >= #{param.call(Posting.day(day))}::date" }
        to.try { |day| clauses << "#{date} <= #{param.call(Posting.day(day))}::date" }
        clauses << "pay.paid_on IS NOT NULL" if basis.payment?
        paid_clause(paid).try { |clause| clauses << clause }
        clauses
      end
    end
  end
end
