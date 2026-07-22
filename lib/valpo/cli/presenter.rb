# frozen_string_literal: true

module Valpo
  module CLI
    class Presenter
      include Formatting
      include Projects
      include Services
      include Domains
      include Releases
      include Jobs
      include Operations
      include System

      attr_reader :err

      def initialize(out:, err:, json:)
        @out = out
        @err = err
        @json = json
      end
    end
  end
end
