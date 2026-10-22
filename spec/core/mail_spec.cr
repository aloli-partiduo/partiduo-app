# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Envoi de courriels par une extension (A-REP-2, DECISIONS D-AMD-025) :
# transport de l'instance partagé avec la Facturation, expéditeur imposé,
# envoi à la validation, journal. Les messages sont capturés : rien ne sort.

private alias Mail = Partiduo::Api::Mail

private PDF_BYTES = "%PDF-1.7\n1 0 obj << >> endobj\n%%EOF\n"

private def sender_actor : Partiduo::Api::Actor
  Partiduo::Api::Actor.user(7_i64, ["core.attachment.read", "core.attachment.write"])
end

private def with_transport(& : Partiduo::Core::Mail::MemoryTransport ->) : Nil
  transport = Partiduo::Core::Mail::MemoryTransport.new
  previous = Partiduo::Core::Mail.transport
  Partiduo::Core::Mail.transport = transport
  begin
    yield transport
  ensure
    Partiduo::Core::Mail.transport = previous
  end
end

private def message(**options) : Mail::MessageInput
  Mail::MessageInput.new(to: ["client@example.test"], subject: "Votre relevé", body: "Bonjour,\nCi-joint votre relevé.")
    .copy_with(**options)
end

describe "Partiduo::Api::Mail (A-REP-2)" do
  it "envoie au nom du dossier, journalise le message et ses pièces" do
    provision_instance(settings_input(email: "contact@exemple.test"))
    with_transport do |transport|
      stored = Partiduo::Api::Core.store_attachment(sender_actor, Partiduo::Api::Core::AttachmentInput.new(
        "contrat.pdf", "application/pdf", IO::Memory.new(PDF_BYTES))).value!
      view = Mail.deliver(sender_actor, message(cc: ["Compta@Example.test; compta@example.test"],
        attachments: [Mail::AttachmentInput.new("../releve.csv", "text/csv", "a;b\n".to_slice)],
        attachment_ids: [stored.id]), "core").value!

      view.status.should eq("sent")
      view.sent?.should be_true
      view.module_code.should eq("CORE")
      view.sender.should eq("contact@exemple.test")
      view.to.should eq(["client@example.test"])
      view.cc.should eq(["Compta@Example.test", "compta@example.test"])
      view.attachments.should eq(["releve.csv", "contrat.pdf"])
      view.sent_by_id.should eq(7)

      sent = transport.messages.first
      sent.from.should eq("contact@exemple.test")
      sent.from_name.should eq("Exemple SARL")
      sent.reply_to.should be_nil
      mime = sent.to_mime
      mime.should contain("From: Exemple SARL <contact@exemple.test>")
      mime.should contain("filename=\"contrat.pdf\"")
      Mail.message(sender_actor, view.id).subject.should eq("Votre relevé")
      Mail.messages(actor_with("core.settings.manage"), "core").map(&.id).should eq([view.id])
    end
  end

  it "part de l'adresse de l'instance, réponses à la société, quand l'instance en impose une" do
    provision_instance(settings_input(email: "contact@exemple.test"))
    ENV["PARTIDUO_MAIL_FROM"] = "noreply@partiduo.test"
    begin
      with_transport do |transport|
        Mail.sender(actor_with).should eq("noreply@partiduo.test")
        Mail.deliver(actor_with, message, "CORE").value!.reply_to.should eq("contact@exemple.test")
        transport.messages.first.to_mime.should contain("Reply-To: contact@exemple.test")
      end
    ensure
      ENV.delete("PARTIDUO_MAIL_FROM")
    end
  end

  it "ne part qu'à la validation : rien ne sort d'une opération annulée" do
    provision_instance(settings_input(email: "contact@exemple.test"))
    with_transport do |transport|
      Partiduo::Api::Transaction.run do
        queued = Mail.deliver(actor_with, message, "CORE").value!
        queued.status.should eq("queued")
        transport.messages.should be_empty
        Partiduo::Api::Result(Nil).failure(Partiduo::Api::FieldError.base("accounting.errors.entry.unbalanced", {"difference" => "0.01"}))
      end
      transport.messages.should be_empty
      Partiduo::Core::MailMessage.all.count.should eq(0)

      kept = 0_i64
      Partiduo::Api::Transaction.run do
        kept = Mail.deliver(actor_with, message, "CORE").value!.id
        Partiduo::Api::Result(Nil).success(nil)
      end
      transport.messages.size.should eq(1)
      Mail.message(actor_with("core.settings.manage"), kept).status.should eq("sent")
    end
  end

  it "journalise un refus du transport" do
    provision_instance(settings_input(email: "contact@exemple.test"))
    with_transport do |transport|
      transport.failure = "550 boîte inconnue"
      view = Mail.deliver(actor_with, message, "CORE").value!
      view.failed?.should be_true
      view.error.should eq("550 boîte inconnue")
      view.sent_at.should be_nil
    end
  end

  it "refuse un message mal formé, sans expéditeur ou sans transport" do
    provision_instance(settings_input(email: ""))
    with_transport do
      result = Mail.deliver(actor_with, message(to: ["pas une adresse"], cc: ["x@y"], subject: " ", body: "x" * 100_001), "CORE")
      result.error_keys.should eq(["core.errors.mail.to.invalid", "core.errors.mail.to.invalid",
                                   "core.errors.mail.subject.blank", "core.errors.mail.body.too_long",
                                   "core.errors.mail.no_sender"])
      ReferentialSpec.expect_translated(result)
      many = (1..51).map { |index| "dest#{index}@example.test" }
      Mail.deliver(actor_with, message(to: many), "CORE").error_keys.should contain("core.errors.mail.to.too_many")
      Mail.deliver(actor_with, message(to: [] of String), "CORE").error_keys.should contain("core.errors.mail.to.blank")
    end
    Partiduo::Core::Mail.transport = Partiduo::Core::Mail::DisabledTransport.new
    begin
      Mail.configured?(actor_with).should be_false
      Mail.deliver(actor_with, message, "CORE").error_keys.should contain("core.errors.mail.not_configured")
    ensure
      Partiduo::Core::Mail.transport = nil
    end
    Partiduo::Core::MailMessage.all.count.should eq(0)
  end

  it "exige un utilisateur authentifié, une pièce active et le droit de lire les pièces citées" do
    provision_instance(settings_input(email: "contact@exemple.test"))
    with_transport do
      expect_raises(Partiduo::Api::Forbidden) { Mail.deliver(Partiduo::Api::Actor.anonymous, message, "CORE") }
      expect_raises(Partiduo::Api::ModuleDisabled) { Mail.deliver(actor_with, message, "INCONNU") }
      expect_raises(Partiduo::Api::Forbidden) { Mail.deliver(actor_with, message(attachment_ids: [1_i64]), "CORE") }
      sent = Mail.deliver(sender_actor, message, "CORE").value!
      expect_raises(Partiduo::Api::NotFound) { Mail.message(Partiduo::Api::Actor.user(8_i64, [] of String), sent.id) }
      expect_raises(Partiduo::Api::Forbidden) { Mail.messages(actor_with) }
    end
  end

  it "partage le transport de l'instance avec la Facturation" do
    with_transport do |transport|
      Partiduo::Invoicing::Mail.transport.should be(transport)
      Partiduo::Api::Invoicing.mail_transport.should be(transport)
    end
  end
end
