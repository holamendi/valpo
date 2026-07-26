# frozen_string_literal: true

module Valpo
  module Builds
    STRATEGIES = %w[auto dockerfile buildpack].freeze
    RESOLVED_STRATEGIES = %w[dockerfile buildpack].freeze
  end
end
