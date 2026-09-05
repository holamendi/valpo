# frozen_string_literal: true

require "json"

module Valpo
  module CLI
    module Commands
      module Server
        class List < BaseCommand
          desc "List saved servers without displaying tokens"

          def call(api_url:, json: false, args: nil, **)
            reject_extra_arguments!(args)
            servers = CLI.sessions.list
            if json
              @out.puts JSON.generate(servers)
            elsif servers.empty?
              @out.puts "No saved servers. Run valpo login --server URL --name NAME."
            else
              servers.each { @out.puts "#{it.fetch("current") ? "*" : " "} #{it.fetch("name")}  #{it.fetch("api_url")}" }
            end
          end
        end
      end
    end
  end
end
