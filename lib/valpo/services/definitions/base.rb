# frozen_string_literal: true

module Valpo
  module Services
    module Definitions
      class Base
        attr_reader :name, :category, :description, :supported_options

        def initialize(name:, category:, description:, supported_options:)
          @name = name
          @category = category
          @description = description
          @supported_options = supported_options.freeze
        end

        def app?
          category == :app
        end

        def managed?
          category == :managed
        end

        def versions
          []
        end

        def default_version
          nil
        end
      end
    end
  end
end
