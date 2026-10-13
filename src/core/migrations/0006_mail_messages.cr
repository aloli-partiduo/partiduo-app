# SPDX-License-Identifier: AGPL-3.0-or-later

# Courriels envoyés par le contrat du socle (A-REP-2) : journal de chaque
# message (pièce qui l'envoie, auteur, expéditeur, destinataires, sujet,
# corps, pièces jointes par nom et empreinte, état de l'envoi).
class Migration::Core::V0006 < Marten::Migration
  depends_on :core, "0005_settings_creditor_identifier"

  def plan
    create_table :core_mail_message do
      column :id, :big_int, primary_key: true, auto: true
      column :module_code, :string, max_size: 32
      column :sent_by_id, :big_int, null: true
      column :sender, :string, max_size: 254
      column :reply_to, :string, max_size: 254, default: ""
      column :recipients, :text
      column :cc, :text, default: ""
      column :subject, :string, max_size: 255
      column :body, :text
      column :attachments, :text, default: ""
      column :message_id, :string, max_size: 100
      column :status, :string, max_size: 8
      column :error, :text, default: ""
      column :created_at, :date_time
      column :sent_at, :date_time, null: true
    end

    execute(
      "ALTER TABLE core_mail_message ADD CONSTRAINT core_mail_message_status_check " \
      "CHECK (status IN ('queued', 'sent', 'failed'))",
      "ALTER TABLE core_mail_message DROP CONSTRAINT IF EXISTS core_mail_message_status_check"
    )
  end
end
