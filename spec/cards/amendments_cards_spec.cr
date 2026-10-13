# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Amendements du contrat des fiches adoptés le 13 octobre 2026 (DECISIONS
# D-AMD-007 et D-AMD-008) : recherche d'une fiche par IBAN (A-BKI-2), pièce
# jointe rattachée à une fiche (A-FRM-2).

private alias Cards = Partiduo::Api::Cards
private alias R = ReferentialSpec

private PDF_BYTES = "%PDF-1.7\n1 0 obj << >> endobj\n%%EOF\n"

private def clerk : Partiduo::Api::Actor
  actor_with("cards.card.read", "cards.card.write", "core.attachment.read", "core.attachment.write")
end

private def stored_attachment(name : String = "contrat.pdf") : Partiduo::Api::Core::AttachmentView
  Partiduo::Api::Core.store_attachment(clerk,
    Partiduo::Api::Core::AttachmentInput.new(name, "application/pdf", IO::Memory.new(PDF_BYTES))).value!
end

describe "Recherche d'une fiche par IBAN (A-BKI-2)" do
  it "trouve la fiche d'un IBAN saisi avec espaces, tirets et minuscules" do
    category = R.category("SUPPLIER", "supplier")
    found = R.card(category.id, "Imprimerie Morel", iban: "FR76 3000 6000 0112 3456 7890 189")
    R.card(category.id, "Papeterie Dubois", iban: "BE68 5390 0754 7034")
    R.card(category.id, "Sans IBAN")

    query = ->(iban : String) { Cards::CardQuery.new(iban: iban, enabled: nil) }
    Cards.cards(clerk, query.call("fr76-3000.6000 0112 3456 7890 189")).map(&.id).should eq([found.id])
    Cards.count_cards(clerk, query.call("FR7630006000011234567890189")).should eq(1)
    Cards.card_ids(clerk, query.call("BE68539007547034").copy_with(kind: "supplier")).size.should eq(1)
  end

  it "ne trouve rien pour un IBAN vide ou inconnu" do
    category = R.category("SUPPLIER", "supplier")
    R.card(category.id, "Sans IBAN")
    Cards.cards(clerk, Cards::CardQuery.new(iban: " ")).should be_empty
    Cards.cards(clerk, Cards::CardQuery.new(iban: "FR7630006000011234567890189")).should be_empty
    # Sans le critère, la recherche est inchangée.
    Cards.cards(clerk, Cards::CardQuery.new).size.should eq(1)
  end
end

describe "Pièces jointes d'une fiche (A-FRM-2)" do
  it "rattache une pièce une seule fois et la liste dans la vue de la fiche" do
    card = R.card(R.category.id)
    first = stored_attachment("contrat.pdf")
    second = stored_attachment("kbis.pdf")
    Cards.attach(clerk, card.id, first.id).value!.filename.should eq("contrat.pdf")
    Cards.attach(clerk, card.id, second.id).success?.should be_true
    Cards.attach(clerk, card.id, first.id).success?.should be_true
    Cards.card_attachments(clerk, card.id).map(&.filename).should eq(%w[contrat.pdf kbis.pdf])
    Cards.card(clerk, card.id).attachments.map(&.id).should eq([first.id, second.id])
    Cards.cards(clerk).first.attachments.size.should eq(2)
  end

  it "ne montre pas les pièces à qui ne peut pas les lire, et refuse de les rattacher" do
    card = R.card(R.category.id)
    attachment = stored_attachment
    Cards.attach(clerk, card.id, attachment.id).value!
    reader = actor_with("cards.card.read", "cards.card.write")
    Cards.card(reader, card.id).attachments.should be_empty
    expect_raises(Partiduo::Api::Forbidden) { Cards.attach(reader, card.id, attachment.id) }
    expect_raises(Partiduo::Api::Forbidden) { Cards.card_attachments(reader, card.id) }
    expect_raises(Partiduo::Api::Forbidden) { Cards.attach(actor_with("core.attachment.read"), card.id, attachment.id) }
  end

  it "refuse une fiche ou une pièce inconnue" do
    card = R.card(R.category.id)
    expect_raises(Partiduo::Api::NotFound) { Cards.attach(clerk, card.id, 999_999_i64) }
    expect_raises(Partiduo::Api::NotFound) { Cards.attach(clerk, 999_999_i64, stored_attachment.id) }
  end

  it "garde la pièce citée, la libère au retrait du lien ou à la suppression de la fiche" do
    card = R.card(R.category.id)
    attachment = stored_attachment
    Cards.attach(clerk, card.id, attachment.id).value!
    Partiduo::Api::Core.delete_attachment(clerk, attachment.id).error_keys.should eq(["core.errors.attachment.in_use"])
    Cards.detach(clerk, card.id, attachment.id).success?.should be_true
    Cards.card_attachments(clerk, card.id).should be_empty
    Cards.detach(clerk, card.id, attachment.id).success?.should be_true

    other = stored_attachment("autre.pdf")
    Cards.attach(clerk, card.id, other.id).value!
    Cards.card_in_use?(clerk, card.id).should be_false
    Cards.delete_card(clerk, card.id).success?.should be_true
    Partiduo::Api::Core.delete_attachment(clerk, other.id).success?.should be_true
  end
end
