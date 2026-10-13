# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Core
    # Écriture de la piste d'audit des approbations (A-SEPA-3). Service
    # interne : le contrat (`Partiduo::Api::Approvals`) et la configuration
    # du dossier (changement de règle) l'appellent.
    module ApprovalLog
      ACTIONS = %w[submitted approved rejected cancelled consumed refused policy.changed]

      def self.record(approval_id : Int64?, action : String, actor_id : Int64?, detail : String = "") : Nil
        raise ArgumentError.new("action d'approbation inconnue : #{action}") unless ACTIONS.includes?(action)
        ApprovalEvent.create!(approval_id: approval_id, action: action, actor_id: actor_id, detail: detail[0, 2000])
      end
    end
  end
end
