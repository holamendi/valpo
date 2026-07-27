# frozen_string_literal: true

module Valpo
  module CLI
    module Commands
      class Version < BaseCommand
        desc "Print the Valpo client version"

        def call(api_url:, json: false, args: nil, **)
          reject_extra_arguments!(args)
          Presenter.new(out: @out, err: @err, json:).version("version" => Valpo::VERSION)
        end
      end
    end
  end
end
