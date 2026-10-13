# SPDX-License-Identifier: AGPL-3.0-or-later

# Pièces jointes d'une fiche (A-FRM-2) : lien entre une fiche et une pièce
# du socle, une fois au plus ; la pièce citée ne peut plus être supprimée
# (clé étrangère sans cascade), la suppression de la fiche retire ses liens.
# Recherche d'une fiche par IBAN (A-BKI-2) : index partiel sur les IBAN
# renseignés.
class Migration::Cards::V0006 < Marten::Migration
  depends_on :cards, "0005_import_permission"
  depends_on :core, "0002_core_referential"

  def plan
    create_table :cards_card_attachment do
      column :id, :big_int, primary_key: true, auto: true
      column :card_id, :reference, to_table: :cards_card, to_column: :id
      column :attachment_id, :reference, to_table: :core_attachment, to_column: :id
      column :attached_by_id, :big_int, null: true
      column :created_at, :date_time
      unique_constraint :cards_card_attachment_unique, [:card_id, :attachment_id]
    end

    execute(
      "CREATE INDEX cards_card_iban_idx ON cards_card (iban) WHERE iban <> ''",
      "DROP INDEX IF EXISTS cards_card_iban_idx"
    )
  end
end
