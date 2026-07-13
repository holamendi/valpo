# frozen_string_literal: true

require "dry/cli"

module Valpo
  module CLI
    DEFAULT_API_URL = "http://127.0.0.1:7092"
    DEFAULT_TIMEOUT = 600
    CONTEXT_FACTORY_KEY = :valpo_cli_context_factory

    module_function

    def call(arguments = ARGV, out: $stdout, err: $stderr, context_factory: nil)
      previous_factory = Thread.current[CONTEXT_FACTORY_KEY]
      Thread.current[CONTEXT_FACTORY_KEY] = context_factory if context_factory
      Runner.new(out: out, err: err).call(arguments)
    ensure
      Thread.current[CONTEXT_FACTORY_KEY] = previous_factory
    end

    def context_factory
      Thread.current[CONTEXT_FACTORY_KEY] || Context.method(:build)
    end
  end
end
