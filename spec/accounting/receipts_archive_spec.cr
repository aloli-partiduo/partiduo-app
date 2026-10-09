# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "compress/zip"

private alias Api = Partiduo::Api::Accounting

private PDF = "%PDF-1.7\n1 0 obj << >> endobj\n%%EOF\n"

private def system
  Partiduo::Api::Actor.system
end

private def attachment(name : String) : Int64
  Partiduo::Api::Core.store_attachment(system,
    Partiduo::Api::Core::AttachmentInput.new(name, "application/pdf", IO::Memory.new(PDF))).value!.id
end

private def entries(content : Bytes) : Hash(String, String)
  files = {} of String => String
  Compress::Zip::Reader.open(IO::Memory.new(content)) do |zip|
    zip.each_entry { |entry| files[entry.filename] = entry.io.gets_to_end }
  end
  files
end

describe_module "ACCOUNTING", "Archive des pièces jointes des écritures (D-OUT-005)" do
  it "rassemble les pièces de la période avec un index, sans toucher aux écritures" do
    EntrySpec.setup
    lines = [EntrySpec.debit("603", "10"), EntrySpec.credit("510001", "10")]
    first = EntrySpec.post_misc(lines, "2026-03-15", attachment_id: attachment("ticket.pdf"))
    second = EntrySpec.post_misc(lines, "2026-03-20", attachment_id: attachment("ticket.pdf"))
    EntrySpec.post_misc(lines, "2026-03-21")
    EntrySpec.post_misc(lines, "2026-05-02", attachment_id: attachment("autre.pdf"))

    _, reader = AccountingSpec.user_actor("lecteur@example.com", "accounting.entry.read", "core.attachment.read")
    file = Api.receipts_archive(reader, EntrySpec.date("2026-03-01"), EntrySpec.date("2026-03-31")).value!
    file.filename.should eq("pieces-20260301-20260331.zip")
    files = entries(file.content)
    files.keys.sort!.should eq(["#{first.internal_code}-ticket.pdf", "#{second.internal_code}-ticket.pdf", "index.csv"].sort)
    files["#{first.internal_code}-ticket.pdf"].should eq(PDF)
    index = files["index.csv"].lines
    index.first.should eq("internal_code;date;ledger;receipt;label;file;sha256")
    index.size.should eq(3)
    index[1].should start_with("#{first.internal_code};2026-03-15;O01;")
  end

  it "se limite au journal demandé, refuse une période sans pièce et exige les droits" do
    EntrySpec.setup
    _, reader = AccountingSpec.user_actor("lecteur@example.com", "accounting.entry.read", "core.attachment.read")
    from, to = EntrySpec.date("2026-01-01"), EntrySpec.date("2026-12-31")
    Api.receipts_archive(reader, from, to).errors.map(&.key).should eq(["accounting.errors.receipts.none"])
    EntrySpec.post_misc([EntrySpec.debit("603", "10"), EntrySpec.credit("510001", "10")], attachment_id: attachment("a.pdf"))
    Api.receipts_archive(reader, from, to, EntrySpec.ledger("A01").id).errors.map(&.key).should eq(["accounting.errors.receipts.none"])
    Api.receipts_archive(reader, from, to, EntrySpec.ledger("O01").id).success?.should be_true
    expect_raises(Partiduo::Api::Forbidden) { Api.receipts_archive(actor_with("accounting.entry.read"), from, to) }
  end
end
