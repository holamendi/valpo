# frozen_string_literal: true

require "securerandom"

module Valpo
  module Identifier
    PREFIXES = {
      project: "prj",
      source: "src",
      build_target: "bld",
      service: "svc",
      dependency: "dep",
      release: "rel",
      domain: "dom",
      job: "job",
      job_event: "evt"
    }.freeze

    module_function

    def generate(type)
      prefix = PREFIXES.fetch(type)
      "#{prefix}_#{SecureRandom.uuid_v7.delete("-")}"
    end

    def valid?(value, type)
      value.to_s.match?(/\A#{Regexp.escape(PREFIXES.fetch(type))}_[0-9a-f]{32}\z/)
    end
  end
end
