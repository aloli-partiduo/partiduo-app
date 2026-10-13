# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    module Accounting
      # Date retenue pour situer une écriture dans une période (A-REP-6) :
      #
      # * `Operation` : la date de l'écriture (comportement antérieur) ;
      # * `Payment` : la date de son paiement, soit la plus récente des
      #   autres écritures lettrées avec ses lignes de tiers, une fois
      #   *toutes* ces lignes lettrées et chaque lettrage équilibré ; une
      #   écriture non payée n'a pas de date de paiement et n'est pas
      #   retenue ;
      # * `Due` : son échéance, sinon sa date.
      enum DateBasis
        Operation
        Payment
        Due

        # Valeur des paramètres et des libellés (`accounting.date_bases.<code>`).
        def code : String
          to_s.underscore
        end

        def self.from_code(code : String) : self
          parse(code)
        end
      end

      # --- Sommes de lignes (A-REP-3) ---------------------------------------------

      # Critères des sommes de lignes, calculées par PostgreSQL :
      #
      # * `account` : numéro exact, ou préfixe avec `account_prefix` ; `nil`,
      #   tous les comptes ;
      # * `counterpart_prefix` : seules comptent les écritures qui portent
      #   aussi une ligne d'un compte commençant par ce numéro (« poste avec
      #   contrepartie ») ;
      # * `card` : seules comptent les écritures qui portent une ligne de
      #   cette fiche (quick code ; « chiffre d'affaires par client ») ;
      #   fiche inconnue : aucune somme ;
      # * `ledger_ids`, `ledger_kinds` : journaux retenus, parmi ceux que
      #   l'acteur voit ;
      # * `date_from`, `date_to` (incluses), selon `date_basis` ; `paid` :
      #   `true` écritures payées, `false` écritures de tiers non payées
      #   (A-REP-6).
      record LineSumQuery,
        account : String? = nil,
        account_prefix : Bool = false,
        counterpart_prefix : String? = nil,
        card : String? = nil,
        ledger_ids : Array(Int64)? = nil,
        ledger_kinds : Array(LedgerKind)? = nil,
        date_from : Time? = nil,
        date_to : Time? = nil,
        date_basis : DateBasis = DateBasis::Operation,
        paid : Bool? = nil

      # Somme des lignes retenues d'un compte : débit, crédit, nombre de
      # lignes ; `balance` = débit − crédit.
      record LineSumView,
        account_number : String,
        account_label : String,
        debit : BigDecimal,
        credit : BigDecimal,
        lines : Int32 do
        def balance : BigDecimal
          debit - credit
        end
      end

      # --- Totaux par code de TVA (A-REP-5) ---------------------------------------

      # Critères des totaux de TVA : période (selon `date_basis`, `paid`),
      # journaux ou types de journal, comptes (numéro exact ou préfixe),
      # codes de taux (`vat_rates`, tous si `nil`).
      record VatTotalsQuery,
        date_from : Time? = nil,
        date_to : Time? = nil,
        ledger_ids : Array(Int64)? = nil,
        ledger_kinds : Array(LedgerKind)? = nil,
        account : String? = nil,
        account_prefix : Bool = false,
        vat_rates : Array(String)? = nil,
        date_basis : DateBasis = DateBasis::Operation,
        paid : Bool? = nil

      # Total d'un taux de TVA pour un compte et un type de journal : base et
      # TVA (lignes de rôle `base` et `tax`), montants signés débit − crédit
      # (positifs pour un achat, négatifs pour une vente), en devise de
      # tenue ; `rate` en pour cent.
      record VatTotalView,
        vat_rate_id : Int64,
        vat_rate_code : String,
        rate : BigDecimal,
        ledger_kind : LedgerKind,
        account_number : String,
        account_label : String,
        base : BigDecimal,
        tax : BigDecimal,
        lines : Int32

      # --- Écritures ouvertes d'une nature de fiche (A-SEPA-1) -------------------

      # Ligne ouverte d'une fiche de tiers : non lettrée, ou (avec
      # `include_partial`) d'un lettrage partiel, dont `matching_remaining`
      # donne le reliquat (débit − crédit de toutes ses lignes). `amount` :
      # montant de la ligne, positif, au sens de `side` ; `overdue` :
      # échéance (sinon date) antérieure à la date de référence.
      record PartyOpenItemView,
        line_id : Int64,
        entry_id : Int64,
        card_id : Int64,
        card_code : String,
        card_name : String,
        account_number : String,
        ledger_id : Int64,
        ledger_code : String,
        date : Time,
        due_date : Time?,
        receipt : String?,
        label : String,
        side : Side,
        amount : BigDecimal,
        overdue : Bool,
        matching_id : Int64? = nil,
        matching_remaining : BigDecimal? = nil do
        # Montant signé débit − crédit.
        def signed : BigDecimal
          side.debit? ? amount : -amount
        end
      end
    end
  end
end
