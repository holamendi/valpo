# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Auth
        module Token
          class Recover < BaseCommand
            desc "Recover API administration from the local host"
            argument :name, required: true, desc: "Recovery credential name"
            option :config, desc: "Path to valpo.yml"
            option :confirm_offline_recovery,
              type: :boolean,
              default: false,
              desc: "Confirm direct local database recovery"

            def call(name:, api_url:, config: nil, confirm_offline_recovery: false, json: false, args: nil, **)
              reject_extra_arguments!(args)
              unless confirm_offline_recovery
                raise UsageError, "Pass --confirm-offline-recovery after stopping or isolating the API"
              end

              recovery = CLI.api_credential_recovery_factory.call(config_path: config)
              credential, token = recovery.call(name:)
              result = {
                id: credential.id,
                name: credential.name,
                scopes: credential.scopes,
                token:
              }
              if json
                @out.puts JSON.generate(result)
              else
                @out.puts "Recovery API credential created. Save this token now; it will not be shown again:"
                @out.puts token
              end
            end
          end
        end
      end
    end
  end
end
