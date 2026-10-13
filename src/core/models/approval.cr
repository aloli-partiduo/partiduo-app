# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Core
    # Demande d'approbation d'une opération sensible (A-SEPA-3), soumise par
    # une extension (`Partiduo::Api::Approvals.submit`) : lot de virements,
    # suppression définitive… Modèle interne ; les décisions passent par le
    # contrat, qui les rend atomiques (mise à jour conditionnelle sur
    # l'état), et la base refuse l'approbation à deux par la même personne.
    class Approval < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :module_code, :string, max_size: 32
      field :kind, :string, max_size: 64
      # Objet de l'extension (`batch:42`) : une seule demande en attente par
      # objet.
      field :subject, :string, max_size: 128
      field :summary, :string, max_size: 255
      field :amount, :decimal, max_digits: 20, decimal_places: 4, null: true, blank: true
      field :currency_code, :string, max_size: 3, blank: true, default: ""
      # Empreinte, calculée par l'extension, de ce qui est soumis : une
      # approbation ne vaut que pour ce contenu (`consume`).
      field :digest, :string, max_size: 128
      # Permission exigée pour décider, déclarée par l'extension.
      field :permission, :string, max_size: 128
      field :details, :json
      # Mode du dossier à la soumission ; celui de la décision est
      # `decision_mode` (le réglage est lu à la décision, D-VAL2-006).
      field :mode, :string, max_size: 8
      field :status, :string, max_size: 12
      field :requested_by_id, :big_int
      field :requested_at, :date_time
      field :decided_by_id, :big_int, null: true, blank: true
      field :decided_at, :date_time, null: true, blank: true
      field :decision_mode, :string, max_size: 8, blank: true, default: ""
      # Authentification forte de la personne qui a approuvé.
      field :strong_auth_at, :date_time, null: true, blank: true
      field :comment, :text, blank: true, default: ""
      field :consumed_by_id, :big_int, null: true, blank: true
      field :consumed_at, :date_time, null: true, blank: true
    end

    # Piste d'audit des approbations (A-SEPA-3), en ajout seul (déclencheur
    # de la migration core 0007) : soumission, approbation, rejet,
    # annulation, consommation, tentative refusée, changement de règle.
    class ApprovalEvent < Marten::Model
      field :id, :big_int, primary_key: true, auto: true
      field :approval, :many_to_one, to: Partiduo::Core::Approval, null: true, blank: true, related: :events
      field :action, :string, max_size: 32
      field :actor_id, :big_int, null: true, blank: true
      field :detail, :text, blank: true, default: ""
      field :created_at, :date_time, auto_now_add: true
    end
  end
end
