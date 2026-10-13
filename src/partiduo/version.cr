# SPDX-License-Identifier: AGPL-3.0-or-later

module Partiduo
  # Version du cœur. Les manifestes d'extension la comparent à `requires_core`.
  # Lue à la compilation dans `shard.yml`, seule source du numéro : chaque
  # commit y incrémente le dernier chiffre.
  VERSION = {{
              (read_file("#{__DIR__}/../../shard.yml")
                .lines
                .find(&.starts_with?("version:")) || "version: 0.0.0")
                .gsub(/^version:\s*/, "")
                .chomp
            }}

  # Version du contrat `Partiduo::Api` (ADR-003 D6, ADR-005 D1). Elle suit le
  # versionnage sémantique : toute rupture du contrat incrémente la majeure ;
  # un ajout incrémente la mineure (0.7.0 : `incompatible_with` du manifeste
  # et de `ModuleView`, types de dossier de `InitialData`, `kind` de
  # `SettingsView` et `ProvisionInput`, ADR-011 A1 et A3 ; 0.8.0 : imports
  # CSV de fiches et du plan comptable, export du plan, archive des pièces,
  # `Transaction.dry_run`, D-OUT-002 à D-OUT-005 ; 0.9.0 : fuseau du
  # dossier, `Core.time_zone` ; 0.10.0 : nature des postes de prévision,
  # `nature` de `ForecastItemInput`, `ForecastItemView` et
  # `ForecastReportItemView`, `forecast_nature`, D-FOY-006 ; 0.11.0 :
  # amendements du socle du 13 octobre 2026, relevés OFX et QIF,
  # `check_attachment`, ICS de la société, saut de page et niveaux de titre
  # du PDF neutre, `incompatible_with_kind`, D-AMD-001 à D-AMD-006 ;
  # 0.12.0 : fiches, critère `iban` de `CardQuery`, pièces jointes d'une
  # fiche, D-AMD-007 à D-AMD-009).
  API_VERSION = "0.12.0"
end

module Partiduo
  # Version du contrat de l'interface en ligne de commande d'instance
  # (`manage instance`, ADR-008 D4, `doc/api/instance-cli.adoc`), consommé
  # par l'exécutant de partiduo-admin. Versionnage sémantique : retirer ou
  # renommer une action, une clé JSON ou un code de sortie incrémente la
  # majeure ; en ajouter incrémente la mineure.
  # 1.2.0 : clé `kind` de `status` et `incompatible_with` de ses modules
  # (ADR-011 A1, A3).
  INSTANCE_CLI_VERSION = "1.2.0"
end
