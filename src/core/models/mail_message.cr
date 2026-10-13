# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  module Core
    # Courriel envoyé par le contrat du socle (A-REP-2) : journal du message
    # et de son envoi. Modèle interne : on n'en crée que par
    # `Partiduo::Api::Mail.deliver`.
    class MailMessage < Marten::Model
      STATUSES = %w[queued sent failed]

      field :id, :big_int, primary_key: true, auto: true
      # Pièce du registre qui envoie (`REPORTS`, `CORE`…).
      field :module_code, :string, max_size: 32
      field :sent_by_id, :big_int, null: true, blank: true
      field :sender, :string, max_size: 254
      field :reply_to, :string, max_size: 254, blank: true, default: ""
      # Adresses séparées par des virgules.
      field :recipients, :text
      field :cc, :text, blank: true, default: ""
      field :subject, :string, max_size: 255
      field :body, :text
      # Pièces jointes, une par ligne : `nom<TAB>empreinte SHA-256`.
      field :attachments, :text, blank: true, default: ""
      field :message_id, :string, max_size: 100
      field :status, :string, max_size: 8
      field :error, :text, blank: true, default: ""
      field :created_at, :date_time, auto_now_add: true
      field :sent_at, :date_time, null: true, blank: true
    end
  end
end
