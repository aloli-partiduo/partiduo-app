# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Accounting
    # Sommes de lignes par critère (A-REP-3) et totaux par code de TVA
    # (A-REP-5), calculés par PostgreSQL. Service interne : les droits et
    # les journaux visibles sont arrêtés par `Partiduo::Api::Accounting`.
    module LineSums
      alias Api = Partiduo::Api::Accounting

      def self.line_sums(query : Api::LineSumQuery, ledger_ids : Array(Int64)) : Array(Api::LineSumView)
        return [] of Api::LineSumView if ledger_ids.empty?
        args = [] of ::DB::Any
        param = ->(value : ::DB::Any) { args << value; "$#{args.size}" }
        clauses = ["e.ledger_id IN (#{ledger_ids.join(", ")})"]
        clauses.concat(EntryDates.clauses(args, query.date_basis, query.paid, query.date_from, query.date_to))
        if number = query.account.try(&.strip).presence
          normalized = Chart.normalize(number)
          clauses << (query.account_prefix ? "a.number LIKE #{param.call(normalized + "%")}" : "a.number = #{param.call(normalized)}")
        end
        if counterpart = query.counterpart_prefix.try(&.strip).presence
          clauses << "EXISTS (SELECT 1 FROM accounting_entry_line c JOIN accounting_account ca ON ca.id = c.account_id " \
                     "WHERE c.entry_id = e.id AND ca.number LIKE #{param.call(Chart.normalize(counterpart) + "%")})"
        end
        if code = query.card.try(&.strip).presence
          card = Partiduo::Api::Cards.card_by_code(Partiduo::Api::Actor.system, code)
          return [] of Api::LineSumView if card.nil?
          clauses << "EXISTS (SELECT 1 FROM accounting_entry_line k WHERE k.entry_id = e.id AND k.card_id = #{param.call(card.id)})"
        end
        sql = <<-SQL
          SELECT a.number, a.label,
                 COALESCE(sum(x.amount) FILTER (WHERE x.side = 'debit'), 0),
                 COALESCE(sum(x.amount) FILTER (WHERE x.side = 'credit'), 0),
                 count(*)
          FROM accounting_entry_line x
          JOIN accounting_entry e ON e.id = x.entry_id
          JOIN accounting_account a ON a.id = x.account_id
          #{EntryDates.join(query.date_basis, query.paid)}
          WHERE #{clauses.join(" AND ")}
          GROUP BY a.number, a.label
          ORDER BY a.number
          SQL
        Marten::DB::Connection.default.open do |db|
          db.query_all(sql, args: args) do |result_set|
            Api::LineSumView.new(
              account_number: result_set.read(String), account_label: result_set.read(String),
              debit: result_set.read(BigDecimal), credit: result_set.read(BigDecimal),
              lines: result_set.read(Int64).to_i32,
            )
          end
        end
      end

      def self.vat_totals(query : Api::VatTotalsQuery, ledger_ids : Array(Int64)) : Array(Api::VatTotalView)
        return [] of Api::VatTotalView if ledger_ids.empty?
        args = [] of ::DB::Any
        param = ->(value : ::DB::Any) { args << value; "$#{args.size}" }
        clauses = ["e.ledger_id IN (#{ledger_ids.join(", ")})", "x.vat_rate_id IS NOT NULL",
                   "x.vat_role IN ('base', 'tax')"]
        clauses.concat(EntryDates.clauses(args, query.date_basis, query.paid, query.date_from, query.date_to))
        if number = query.account.try(&.strip).presence
          normalized = Chart.normalize(number)
          clauses << (query.account_prefix ? "a.number LIKE #{param.call(normalized + "%")}" : "a.number = #{param.call(normalized)}")
        end
        if codes = query.vat_rates
          return [] of Api::VatTotalView if codes.empty?
          placeholders = codes.map { |code| param.call(code.strip.upcase) }
          clauses << "r.code IN (#{placeholders.join(", ")})"
        end
        signed = "CASE WHEN x.side = 'debit' THEN x.amount ELSE -x.amount END"
        sql = <<-SQL
          SELECT r.id, r.code, r.rate, l.kind, a.number, a.label,
                 COALESCE(sum(#{signed}) FILTER (WHERE x.vat_role = 'base'), 0),
                 COALESCE(sum(#{signed}) FILTER (WHERE x.vat_role = 'tax'), 0),
                 count(*)
          FROM accounting_entry_line x
          JOIN accounting_entry e ON e.id = x.entry_id
          JOIN accounting_ledger l ON l.id = e.ledger_id
          JOIN accounting_account a ON a.id = x.account_id
          JOIN vat_rate r ON r.id = x.vat_rate_id
          #{EntryDates.join(query.date_basis, query.paid)}
          WHERE #{clauses.join(" AND ")}
          GROUP BY r.id, r.code, r.rate, l.kind, a.number, a.label
          ORDER BY r.code, l.kind, a.number
          SQL
        Marten::DB::Connection.default.open do |db|
          db.query_all(sql, args: args) do |result_set|
            Api::VatTotalView.new(
              vat_rate_id: result_set.read(Int64), vat_rate_code: result_set.read(String),
              rate: result_set.read(BigDecimal), ledger_kind: Api::LedgerKind.from_code(result_set.read(String)),
              account_number: result_set.read(String), account_label: result_set.read(String),
              base: result_set.read(BigDecimal), tax: result_set.read(BigDecimal), lines: result_set.read(Int64).to_i32,
            )
          end
        end
      end
    end

    # Lignes ouvertes de toutes les fiches d'une nature (A-SEPA-1), avec les
    # règles d'`aged_balance` arrêtée à une date. Service interne.
    module OpenItems
      alias Api = Partiduo::Api::Accounting

      def self.list(cards : Hash(Int64, Partiduo::Api::Cards::CardView), ledger_ids : Array(Int64), as_of : Time,
                    include_partial : Bool) : Array(Api::PartyOpenItemView)
        return [] of Api::PartyOpenItemView if cards.empty? || ledger_ids.empty?
        sql = <<-SQL
          SELECT x.id, e.id, x.card_id, a.number, l.id, l.code, e.date, e.due_date, e.receipt,
                 COALESCE(NULLIF(x.label, ''), e.label), x.side, x.amount, x.matching_id
          FROM accounting_entry_line x
          JOIN accounting_entry e ON e.id = x.entry_id
          JOIN accounting_ledger l ON l.id = e.ledger_id
          JOIN accounting_account a ON a.id = x.account_id
          WHERE x.card_id IN (#{cards.keys.join(", ")}) AND e.ledger_id IN (#{ledger_ids.join(", ")})
            AND e.date <= $1::date
          ORDER BY e.date, e.id, x.position
          SQL
        rows = Marten::DB::Connection.default.open do |db|
          db.query_all(sql, args: [as_of.as(::DB::Any)]) do |result_set|
            {result_set.read(Int64), result_set.read(Int64), result_set.read(Int64), result_set.read(String),
             result_set.read(Int64), result_set.read(String), result_set.read(Time), result_set.read(Time?),
             result_set.read(String?), result_set.read(String), result_set.read(String), result_set.read(BigDecimal),
             result_set.read(Int64?)}
          end
        end
        matching_ids = rows.compact_map(&.[12]).uniq!
        differences = EntryQueries.matching_differences(matching_ids, as_of)
        alone = lone_matchings(matching_ids, as_of)
        items = rows.compact_map do |(line_id, entry_id, card_id, account, ledger_id, ledger_code, date, due_date, receipt, label, side, amount, matching_id)|
          remaining = nil
          # Lettrée après `as_of` seulement : ouverte à cette date.
          matching_id = nil if matching_id && alone.includes?(matching_id)
          if matching_id
            difference = differences[matching_id]? || BigDecimal.new(0)
            next if difference.zero? || !include_partial
            remaining = difference
          end
          card = cards[card_id]
          Api::PartyOpenItemView.new(
            line_id: line_id, entry_id: entry_id, card_id: card_id, card_code: card.code, card_name: card.name,
            account_number: account, ledger_id: ledger_id, ledger_code: ledger_code, date: date, due_date: due_date,
            receipt: receipt, label: label, side: Api::Side.from_code(side), amount: amount,
            overdue: (due_date || date) < as_of, matching_id: matching_id, matching_remaining: remaining,
          )
        end
        items.sort_by { |item| {item.card_name.downcase, item.card_code, item.date, item.entry_id, item.line_id} }
      end

      # Lettrages qui, au jour `as_of`, ne réunissent qu'une ligne : les
      # autres sont postérieures.
      private def self.lone_matchings(ids : Array(Int64), as_of : Time) : Set(Int64)
        return Set(Int64).new if ids.empty?
        sql = "SELECT x.matching_id FROM accounting_entry_line x JOIN accounting_entry e ON e.id = x.entry_id " \
              "WHERE x.matching_id IN (#{ids.join(", ")}) AND e.date <= $1::date " \
              "GROUP BY x.matching_id HAVING count(*) = 1"
        Marten::DB::Connection.default.open do |db|
          db.query_all(sql, args: [as_of.as(::DB::Any)], as: Int64).to_set
        end
      end
    end
  end
end
