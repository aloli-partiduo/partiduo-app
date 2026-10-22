# SPDX-License-Identifier: AGPL-3.0-or-later

require "./events"
require "./manifest"
require "./registry"
require "./models/**"
require "./state"
require "./api/**"

module Partiduo
  module Modules
    # Application Marten du registre (ADR-003 D2, ADR-006 D1). Sa mise en place
    # vérifie la cohérence des pièces enregistrées et de l'ensemble actif : une
    # incohérence empêche le démarrage (`ConfigurationError`).
    class App < Marten::App
      label "modules"

      def setup
        Partiduo::Modules.check!
        # Dossier provisionné avant `core_settings.provisioned_modules` :
        # pièces reprises de la variable au premier démarrage (D-AMD-036).
        if Partiduo::Modules::State.record_provisioned_codes
          ::Log.for("partiduo.modules").info { "pièces retenues reprises de PARTIDUO_MODULES (D-AMD-036)" }
        end
      end
    end
  end
end
