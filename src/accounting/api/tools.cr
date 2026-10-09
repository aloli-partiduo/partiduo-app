# SPDX-License-Identifier: AGPL-3.0-or-later

require "compress/zip"
require "digest/sha256"

module Partiduo
  module Api
    # Contrat du module Comptabilité — outils du plan comptable et des
    # pièces (D-OUT-004, D-OUT-005) : import et export du plan comptable en
    # CSV, archive des pièces jointes des écritures d'une période.
    module Accounting
      # Import du plan comptable : permission propre, en plus de
      # `accounting.account.write` qu'exige chaque compte créé ou modifié.
      CHART_IMPORT_PERMISSION = "accounting.account.import"

      # Champs d'une ligne du plan : numéro et libellé (exigés), parent, type
      # (code, code d'origine `ACT`/`PAS`/`PRO`/`CHA`/`CON` suffixé ou non de
      # `INV`, ou libellé), utilisation directe.
      def self.chart_import_fields(actor : Actor) : Array(Core::ImportFieldView)
        Guard.authorize!(actor, CHART_IMPORT_PERMISSION, module_code: MODULE_CODE)
        Partiduo::Accounting::ChartImport::FIELDS
      end

      # Aperçu à blanc : chaque ligne passe par `create_account` (ou
      # `update_account` avec `source.update_existing` : libellé, parent,
      # type, utilisation directe des cellules non vides ; le numéro ne
      # change pas), puis tout est annulé. Un numéro existant est refusé sans
      # `update_existing`. Sans en-tête reconnu : numéro ; libellé ; parent ;
      # type, comme le format d'origine (parent `0` : aucun).
      def self.preview_chart_import(actor : Actor, source : Core::ImportSource) : Core::ImportView
        authorize_chart_import!(actor)
        Transaction.dry_run { Partiduo::Accounting::ChartImport.run(actor, source) }
      end

      # Importe le plan dans une seule transaction ; mêmes échecs que
      # `Cards.import_cards` (`core.errors.import.*`). Le remplacement du
      # plan entier n'existe pas (D-OUT-004).
      def self.import_chart(actor : Actor, source : Core::ImportSource, skip_refused : Bool = false) : Result(Core::ImportView)
        authorize_chart_import!(actor)
        Transaction.run do
          view = Partiduo::Accounting::ChartImport.run(actor, source)
          Partiduo::Core::CsvImport.outcome(view, skip_refused)
        end
      end

      # Plan comptable au format de l'import (CSV, `;`, UTF-8, en-tête de
      # libellés, ordre de l'arbre).
      def self.export_chart(actor : Actor) : FileView
        Guard.authorize!(actor, "accounting.account.read", module_code: MODULE_CODE)
        FileView.new("#{I18n.t("accounting.import.export_name")}.csv", "text/csv", Partiduo::Accounting::ChartImport.csv)
      end

      # Archive ZIP des pièces jointes des écritures d'une période (dates
      # comprises), des journaux visibles ou du seul journal `ledger_id` ;
      # un index CSV (code interne, date, journal, pièce, libellé, fichier,
      # empreinte SHA-256) les relie aux écritures. Lecture seule : ni
      # renumérotation ni modification des pièces (D-OUT-006). Échec
      # `accounting.errors.receipts.none` sans pièce jointe.
      def self.receipts_archive(actor : Actor, date_from : Time, date_to : Time,
                                ledger_id : Int64? = nil) : Result(FileView)
        Guard.authorize!(actor, "accounting.entry.read", module_code: MODULE_CODE)
        Guard.authorize!(actor, "core.attachment.read")
        ledger_ids = readable_ledger_ids(actor)
        if ledger_id
          raise NotFound.new("ledger", ledger_id) unless ledger_ids.includes?(ledger_id)
          ledger_ids = [ledger_id]
        end
        entries = Partiduo::Accounting::Entry.filter(ledger_id__in: ledger_ids, date__gte: date_from, date__lte: date_to,
          attachment_id__isnull: false).order(:date, :id).to_a
        if entries.empty?
          return Result(FileView).failure(FieldError.base("accounting.errors.receipts.none"))
        end
        name = "#{I18n.t("accounting.receipts.archive_name")}-#{date_from.to_s("%Y%m%d")}-#{date_to.to_s("%Y%m%d")}.zip"
        Result(FileView).success(FileView.new(name, "application/zip", receipts_zip(actor, entries)))
      end

      private def self.receipts_zip(actor : Actor, entries : Array(Partiduo::Accounting::Entry)) : Bytes
        ledgers = Partiduo::Accounting::Ledger.all.to_a.to_h { |ledger| {ledger.pk!.as(Int64), ledger.code.to_s} }
        names = Set(String).new
        files = [] of {String, Bytes}
        index = CSV.build(separator: ';') do |csv|
          csv.row %w[internal_code date ledger receipt label file sha256]
          entries.each do |entry|
            attachment_id = entry.attachment_id.as(Int).to_i64
            attachment = Core.attachment(actor, attachment_id)
            content = Core.attachment_content(actor, attachment_id)
            name = unique_name(names, "#{entry.internal_code}-#{Partiduo::Core::Attachments.clean_filename(attachment.filename)}")
            files << {name, content}
            csv.row [entry.internal_code.to_s, entry.date!.to_s("%Y-%m-%d"), ledgers[entry.ledger_id.as(Int).to_i64]? || "",
                     Partiduo::Core::TableOutput.csv_text(entry.receipt.to_s), Partiduo::Core::TableOutput.csv_text(entry.label.to_s),
                     name, Digest::SHA256.hexdigest(content)]
          end
        end
        io = IO::Memory.new
        Compress::Zip::Writer.open(io) do |zip|
          files.each { |(name, content)| zip.add(name, content) }
          zip.add("index.csv", index)
        end
        io.to_slice
      end

      # Nom de fichier unique dans l'archive (une même pièce peut servir
      # plusieurs écritures, deux fichiers porter le même nom).
      private def self.unique_name(names : Set(String), name : String) : String
        candidate = name
        number = 1
        until names.add?(candidate)
          number += 1
          extension = File.extname(name)
          candidate = "#{name.rchop(extension)}-#{number}#{extension}"
        end
        candidate
      end

      private def self.authorize_chart_import!(actor : Actor) : Nil
        Guard.authorize!(actor, CHART_IMPORT_PERMISSION, module_code: MODULE_CODE)
        Guard.authorize!(actor, "accounting.account.write", module_code: MODULE_CODE)
      end
    end
  end
end
