# frozen_string_literal: true

require "io/console"
require "json"

module Valpo
  module CLI
    module Commands
      module Auth
        class Base < BaseCommand
          private

          def github!(provider)
            return "github" if provider.to_s.downcase == "github"

            raise UsageError, "Unsupported authentication provider. Supported providers: github"
          end
        end
      end
    end
  end
end
