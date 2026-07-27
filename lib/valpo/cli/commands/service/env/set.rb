# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      module Service
        module Env
          class Set < BaseCommand
            desc "Set an encrypted environment variable on an app service"
            argument :service, required: true, desc: "Service name or ID"
            argument :name, required: true, desc: "Environment variable name"
            project_option
            option :plain, type: :boolean, default: false, desc: "Display the value without redaction"
            wait_options

            def call(service:, name:, plain:, wait:, timeout:, api_url:, project: nil, json: false, args: nil, **)
              reject_extra_arguments!(args)
              current = context(api_url:, json:)
              response = current.request(
                :put,
                "#{current.service_path(service, project:)}/env/#{segment(name)}",
                {"value" => read_value, "sensitive" => !plain}
              )
              current.presenter.operation(current.finish_operation(response, wait:, timeout:))
            end

            private

            def read_value
              input = Valpo::CLI.input
              value = if input.respond_to?(:tty?) && input.tty?
                @err.print "Value: "
                result = input.respond_to?(:noecho) ? input.noecho(&:gets) : input.gets
                @err.puts
                result
              else
                input.read
              end
              raise UsageError, "Environment variable value is required on stdin" if value.nil?

              value.to_s.sub(/\r?\n\z/, "")
            end
          end
        end
      end
    end
  end
end
