# frozen_string_literal: true

require "json"

module Valpo
  module CLI
    module Commands
      module Server
        class Use < BaseCommand
          desc "Select the default saved server"
          argument :name, required: true, desc: "Saved server name"

          def call(name:, api_url:, json: false, args: nil, **)
            reject_extra_arguments!(args)
            result = CLI.sessions.use(name)
            @out.puts(json ? JSON.generate(result) : "Selected server #{name}")
          end
        end
      end
    end
  end
end
