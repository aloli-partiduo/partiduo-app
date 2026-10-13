# SPDX-License-Identifier: AGPL-3.0-or-later

# Validation à deux et authentification forte récente pour les opérations
# sensibles des dossiers (A-SEPA-3) :
#
# * réglage du dossier : `approval_mode` (`single`, défaut ; `dual`) et délai
#   de l'authentification forte exigée pour approuver
#   (`approval_reauth_minutes`, 5 par défaut, de 1 à 60) ;
# * `core_approval` : demandes d'approbation soumises par les extensions ;
#   la base refuse qu'une demande approuvée en validation à deux le soit par
#   la personne qui l'a soumise, et qu'une demande soit consommée sans être
#   approuvée ; une seule demande en attente par objet ;
# * `core_approval_event` : piste d'audit (soumission, décisions, refus,
#   consommation, changement de réglage), en ajout seul.
class Migration::Core::V0007 < Marten::Migration
  depends_on :core, "0006_mail_messages"

  def plan
    add_column :core_settings, :approval_mode, :string, max_size: 8, default: "single"
    add_column :core_settings, :approval_reauth_minutes, :int, default: 5

    create_table :core_approval do
      column :id, :big_int, primary_key: true, auto: true
      column :module_code, :string, max_size: 32
      column :kind, :string, max_size: 64
      column :subject, :string, max_size: 128
      column :summary, :string, max_size: 255
      column :amount, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :currency_code, :string, max_size: 3, default: ""
      column :digest, :string, max_size: 128
      column :permission, :string, max_size: 128
      column :details, :json
      column :mode, :string, max_size: 8
      column :status, :string, max_size: 12
      column :requested_by_id, :big_int
      column :requested_at, :date_time
      column :decided_by_id, :big_int, null: true
      column :decided_at, :date_time, null: true
      column :decision_mode, :string, max_size: 8, default: ""
      column :strong_auth_at, :date_time, null: true
      column :comment, :text, default: ""
      column :consumed_by_id, :big_int, null: true
      column :consumed_at, :date_time, null: true
    end

    create_table :core_approval_event do
      column :id, :big_int, primary_key: true, auto: true
      column :approval_id, :reference, to_table: :core_approval, to_column: :id, null: true
      column :action, :string, max_size: 32
      column :actor_id, :big_int, null: true
      column :detail, :text, default: ""
      column :created_at, :date_time
    end

    execute(
      "ALTER TABLE core_settings " \
      "ADD CONSTRAINT core_settings_approval_mode_check CHECK (approval_mode IN ('single', 'dual')), " \
      "ADD CONSTRAINT core_settings_approval_reauth_check CHECK (approval_reauth_minutes BETWEEN 1 AND 60)",
      "ALTER TABLE core_settings DROP CONSTRAINT IF EXISTS core_settings_approval_reauth_check, " \
      "DROP CONSTRAINT IF EXISTS core_settings_approval_mode_check"
    )
    execute(<<-SQL, "ALTER TABLE core_approval DROP CONSTRAINT IF EXISTS core_approval_status_check, DROP CONSTRAINT IF EXISTS core_approval_mode_check, DROP CONSTRAINT IF EXISTS core_approval_dual_check, DROP CONSTRAINT IF EXISTS core_approval_decided_check, DROP CONSTRAINT IF EXISTS core_approval_consumed_check")
      ALTER TABLE core_approval
        ADD CONSTRAINT core_approval_status_check
          CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled')),
        ADD CONSTRAINT core_approval_mode_check CHECK (mode IN ('single', 'dual')),
        ADD CONSTRAINT core_approval_dual_check
          CHECK (status <> 'approved' OR decision_mode <> 'dual' OR decided_by_id IS DISTINCT FROM requested_by_id),
        ADD CONSTRAINT core_approval_decided_check
          CHECK (status = 'pending' OR (decided_at IS NOT NULL AND (status = 'cancelled' OR decided_by_id IS NOT NULL))),
        ADD CONSTRAINT core_approval_consumed_check
          CHECK (consumed_at IS NULL OR status = 'approved')
      SQL
    execute(
      "CREATE UNIQUE INDEX core_approval_pending_subject ON core_approval (module_code, kind, subject) WHERE status = 'pending'",
      "DROP INDEX IF EXISTS core_approval_pending_subject"
    )
    execute(
      "CREATE INDEX core_approval_status_idx ON core_approval (status, module_code)",
      "DROP INDEX IF EXISTS core_approval_status_idx"
    )
    execute(<<-SQL, "DROP FUNCTION IF EXISTS core_approval_event_append_only()")
      CREATE FUNCTION core_approval_event_append_only() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'piste d''audit des approbations : ajout seul';
      END;
      $$ LANGUAGE plpgsql
      SQL
    execute(
      "CREATE TRIGGER core_approval_event_append_only BEFORE UPDATE OR DELETE ON core_approval_event " \
      "FOR EACH ROW EXECUTE FUNCTION core_approval_event_append_only()",
      "DROP TRIGGER IF EXISTS core_approval_event_append_only ON core_approval_event"
    )
  end
end
