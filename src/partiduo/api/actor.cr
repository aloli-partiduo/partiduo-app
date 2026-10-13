# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Api
    # Qui appelle le contrat. Toute commande et toute requête reçoivent un
    # acteur en premier argument et vérifient ses droits (ADR-005 D2).
    #
    # L'interface obtient l'acteur de l'utilisateur connecté par
    # `Partiduo::Api::Auth.actor(jeton de session)` (droits de son profil,
    # niveau de sécurité de sa session — ADR-002 D2) ; les outils en ligne de
    # commande (`partiduo-provision`, `partiduo-migrate`) utilisent `Actor.system`.
    #
    # `level` : niveau de la session (0 enrôlement, 1 mot de passe,
    # 2 mot de passe + TOTP, 3 passkey), 3 pour l'acteur système.
    #
    # `elevated` : la session a atteint le niveau qu'exige l'utilisateur
    # (ADR-002 D2, D6). Faux : l'acteur est authentifié, mais seules les
    # opérations de son propre compte lui sont ouvertes
    # (`Guard.authorize_account!`) ; `Guard.authorize!` le refuse, même sans
    # permission citée (D-AUTH-013).
    #
    # `session_id` : session d'où vient l'acteur (conservée quand un
    # changement de sécurité coupe les autres sessions).
    #
    # `strong_auth_at` (A-SEPA-3) : heure de la dernière authentification
    # forte de la session (TOTP, passkey, identité fédérée, au niveau
    # qu'exige l'utilisateur ; ni code de récupération, ni mot de passe
    # seul) ; `nil` s'il n'y en a pas eu. Une opération sensible exige
    # qu'elle soit récente (`strong_auth_within?`) : c'est la règle des
    # approbations (`Partiduo::Api::Approvals`).
    record Actor, user_id : Int64?, permissions : Set(String), system : Bool = false, level : Int32 = 0,
      elevated : Bool = true, session_id : Int64? = nil, strong_auth_at : Time? = nil do
      # Acteur technique : toutes les permissions. Réservé aux outils en ligne
      # de commande et aux abonnés d'événements, jamais à une requête HTTP.
      def self.system : Actor
        new(nil, Set(String).new, true, 3)
      end

      # Acteur non authentifié : aucune permission.
      def self.anonymous : Actor
        new(nil, Set(String).new)
      end

      def self.user(user_id : Int64, permissions : Enumerable(String), level : Int32 = 0,
                    elevated : Bool = true, session_id : Int64? = nil, strong_auth_at : Time? = nil) : Actor
        new(user_id, permissions.to_set, false, level, elevated, session_id, strong_auth_at)
      end

      def authenticated? : Bool
        system || !user_id.nil?
      end

      def can?(permission : String) : Bool
        system || (authenticated? && permissions.includes?(permission))
      end

      # L'acteur, une personne, s'est-il authentifié fortement depuis moins
      # de `window` (à `now`) ? Jamais vrai pour l'acteur système : une
      # approbation est le geste d'une personne.
      def strong_auth_within?(window : Time::Span, now : Time = Time.utc) : Bool
        return false if system || user_id.nil?
        at = strong_auth_at || return false
        at <= now + 1.minute && now - at <= window
      end
    end
  end
end
