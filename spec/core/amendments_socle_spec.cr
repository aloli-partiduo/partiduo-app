# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "pdf-validate"

# Amendements du contrat du socle adoptés le 13 octobre 2026 (ADR-003,
# DECISIONS D-AMD-001 à D-AMD-005) : relevés OFX et QIF en pièce jointe
# (A-BKI-1), contrôle d'une pièce sans la stocker (A-FRM-3), identifiant
# créancier SEPA de la société (A-SEPA-2), saut de page et niveaux de titre
# du PDF neutre (A-REP-4), pièce exclue d'un type de dossier (A-AMO-1).

private alias Core = Partiduo::Api::Core

private PDF_BYTES = "%PDF-1.7\n1 0 obj << >> endobj\n%%EOF\n"
private OFX_TEXT  = "OFXHEADER:100\nDATA:OFXSGML\nVERSION:102\n\n<OFX><BANKMSGSRSV1></BANKMSGSRSV1></OFX>\n"
private QIF_TEXT  = "!Type:Bank\nD10/01/2026\nT-12.50\nPBoulangerie\n^\n"

private def attachment_writer : Partiduo::Api::Actor
  actor_with("core.attachment.read", "core.attachment.write")
end

private def attachment_input(content : String, filename : String, content_type : String) : Core::AttachmentInput
  Core::AttachmentInput.new(filename, content_type, IO::Memory.new(content))
end

private def settings_admin : Partiduo::Api::Actor
  actor_with("core.settings.manage")
end

private def table(rows : Array(Core::TableRowInput)) : Core::TableInput
  Core::TableInput.new(name: "rapport", title: "Rapport",
    columns: [Core::TableColumnInput.new("Poste", weight: 3.0), Core::TableColumnInput.new("Montant", "amount")],
    rows: rows)
end

private def page_count(content : Bytes) : Int32
  String.new(content).scrub.scan(/\/Type\s*\/Page(?!s)/).size
end

describe "Pièces jointes : relevés OFX et QIF (A-BKI-1)" do
  it "admet un OFX et un QIF, gardés sous leur type et leur extension" do
    ofx = Core.store_attachment(attachment_writer, attachment_input(OFX_TEXT, "releve.ofx", "application/x-ofx")).value!
    ofx.content_type.should eq("application/x-ofx")
    qif = Core.store_attachment(attachment_writer, attachment_input(QIF_TEXT, "releve.qif", "application/qif")).value!
    qif.content_type.should eq("application/qif")
    Core.attachment_content(attachment_writer, ofx.id).should eq(OFX_TEXT.to_slice)
    Partiduo::Core::Attachment.filter(id: qif.id).first!.storage_name!.should end_with(".qif")
    Core.attachment_types["application/x-ofx"].should eq(".ofx")
  end

  it "refuse un OFX qui contient un octet nul (contrôlé comme du texte)" do
    result = Core.store_attachment(attachment_writer, attachment_input("OFX\0binaire", "releve.ofx", "application/x-ofx"))
    result.error_keys.should eq(["core.errors.attachment.content_type.mismatch"])
  end
end

describe "Contrôle d'une pièce sans stockage (A-FRM-3)" do
  it "contrôle le type, la signature, la taille et le nom, pour un anonyme, sans rien stocker" do
    before = Partiduo::Core::Attachment.all.count
    view = Core.check_attachment(Partiduo::Api::Actor.anonymous,
      attachment_input(PDF_BYTES, "../../justificatif.pdf", "application/pdf; charset=binary")).value!
    view.filename.should eq("justificatif.pdf")
    view.content_type.should eq("application/pdf")
    view.byte_size.should eq(PDF_BYTES.bytesize)
    view.sha256.should eq(Digest::SHA256.hexdigest(PDF_BYTES))
    Partiduo::Core::Attachment.all.count.should eq(before)
  end

  it "rend les mêmes refus que le versement" do
    input = -> { attachment_input("GIF89a", " ", "image/png") }
    checked = Core.check_attachment(Partiduo::Api::Actor.anonymous, input.call)
    stored = Core.store_attachment(attachment_writer, input.call)
    checked.error_keys.should eq(["core.errors.attachment.filename.blank", "core.errors.attachment.content_type.mismatch"])
    checked.error_keys.should eq(stored.error_keys)
    Core.check_attachment(Partiduo::Api::Actor.anonymous, attachment_input("x", "a.exe", "application/x-msdownload"))
      .error_keys.should eq(["core.errors.attachment.content_type.unsupported"])
    big = "%PDF-" + "a" * Partiduo::Core::Attachments::MAX_BYTES
    Core.check_attachment(Partiduo::Api::Actor.anonymous, attachment_input(big, "gros.pdf", "application/pdf"))
      .error_keys.should eq(["core.errors.attachment.content.too_large"])
  end

  it "reconnaît le type d'un contenu à sa signature, parmi des types admis" do
    png = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]
    among = %w[application/pdf image/png image/jpeg]
    Core.detect_attachment_type(PDF_BYTES.to_slice, among).should eq("application/pdf")
    Core.detect_attachment_type(png, among).should eq("image/png")
    Core.detect_attachment_type("texte".to_slice, among).should be_nil
    Core.detect_attachment_type("texte".to_slice, among + ["text/plain"]).should eq("text/plain")
    Core.detect_attachment_type(PDF_BYTES.to_slice, ["application/x-inconnu"]).should be_nil
  end
end

describe "Identifiant créancier SEPA de la société (A-SEPA-2)" do
  it "contrôle la clé de l'ICS, le garde sous sa forme compacte et l'expose à la vue" do
    Partiduo::Core::Identifiers.valid_creditor_identifier?("FR72ZZZ123456").should be_true
    Partiduo::Core::Identifiers.valid_creditor_identifier?("BE69ZZZ050D000000008").should be_true
    Partiduo::Core::Identifiers.valid_creditor_identifier?("FR73ZZZ123456").should be_false
    Partiduo::Core::Identifiers.valid_creditor_identifier?("FR72ZZ").should be_false

    provision_instance
    view = Core.update_settings(settings_admin, settings_input(creditor_identifier: "fr 72 zzz 123456")).value!
    view.creditor_identifier.should eq("FR72ZZZ123456")
    Core.settings(actor_with).creditor_identifier.should eq("FR72ZZZ123456")
    view.to_input.creditor_identifier.should eq("FR72ZZZ123456")
  end

  it "garde l'ICS quand la saisie ne le cite pas, l'efface sur une chaîne vide, refuse une clé fausse" do
    provision_instance(settings_input(creditor_identifier: "FR72ZZZ123456"))
    Core.update_settings(settings_admin, settings_input(city: "Rezé")).value!.creditor_identifier.should eq("FR72ZZZ123456")
    refused = Core.update_settings(settings_admin, settings_input(creditor_identifier: "FR73ZZZ123456"))
    refused.error_keys.should eq(["core.errors.settings.creditor_identifier.invalid"])
    ReferentialSpec.expect_translated(refused)
    Core.check_settings(settings_admin, settings_input(creditor_identifier: "FR73ZZZ123456"))
      .error_keys.should eq(["core.errors.settings.creditor_identifier.invalid"])
    Core.update_settings(settings_admin, settings_input(creditor_identifier: "")).value!.creditor_identifier.should eq("")
  end
end

describe "PDF neutre : saut de page et niveaux de titre (A-REP-4)" do
  it "commence une page à chaque saut, sauf en tête de page, et reste un PDF/A-2b valide" do
    provision_instance
    rows = [
      Core::TableRowInput.new(["Charges"], "heading", level: 1),
      Core::TableRowInput.new(["Achats", "120,00"]),
      Core::TableRowInput.new([] of String, "page_break"),
      Core::TableRowInput.new([] of String, "page_break"),
      Core::TableRowInput.new(["Produits"], "heading", level: 2),
      Core::TableRowInput.new(["Ventes"], "heading", level: 3),
      Core::TableRowInput.new(["Prestations", "300,00"]),
    ]
    file = Core.table_pdf(actor_with, table(rows)).value!
    page_count(file.content).should eq(2)
    PDF::Validate.bytes(file.content, profile: "pdf-a-2b").fatal_failures.map(&.rule.id).should eq([] of String)
    plain = Core.table_pdf(actor_with, table(rows.reject(&.style.==("page_break")))).value!
    page_count(plain.content).should eq(1)
  end

  it "refuse un niveau hors de 0 à 3, ou un niveau sur une ligne qui n'est pas un titre" do
    provision_instance
    Core.table_pdf(actor_with, table([Core::TableRowInput.new(["X"], "heading", level: 4)]))
      .error_keys.should eq(["core.errors.table.rows.row"])
    Core.table_pdf(actor_with, table([Core::TableRowInput.new(["X", "1"], "line", level: 1)]))
      .error_keys.should eq(["core.errors.table.rows.row"])
  end

  it "omet les sauts de page du CSV des éditions" do
    table = Partiduo::Core::TableOutput::Table.new("t", "T", [] of String,
      [Partiduo::Core::TableOutput::Column.new("A")],
      [Partiduo::Core::TableOutput::Row.new(["a"] of Partiduo::Core::TableOutput::Cell),
       Partiduo::Core::TableOutput::Row.new([] of Partiduo::Core::TableOutput::Cell, :page_break),
       Partiduo::Core::TableOutput::Row.new(["b"] of Partiduo::Core::TableOutput::Cell)])
    String.new(Partiduo::Core::TableOutput.csv(table)).should eq("A\na\nb\n")
  end
end
