# frozen_string_literal: true

require "dry/cli"

module Valpo
  module CLI
    DEFAULT_API_URL = "http://127.0.0.1:7092"
    DEFAULT_TIMEOUT = 600
    CONTEXT_FACTORY_KEY = :valpo_cli_context_factory
    GITHUB_VALIDATOR_KEY = :valpo_cli_github_validator
    INPUT_KEY = :valpo_cli_input

    module_function

    def call(arguments = ARGV, out: $stdout, err: $stderr, input: $stdin, context_factory: nil, github_validator: nil)
      previous_factory = Thread.current[CONTEXT_FACTORY_KEY]
      previous_validator = Thread.current[GITHUB_VALIDATOR_KEY]
      previous_input = Thread.current[INPUT_KEY]
      Thread.current[CONTEXT_FACTORY_KEY] = context_factory if context_factory
      Thread.current[GITHUB_VALIDATOR_KEY] = github_validator if github_validator
      Thread.current[INPUT_KEY] = input
      Runner.new(out:, err:).call(arguments)
    ensure
      Thread.current[CONTEXT_FACTORY_KEY] = previous_factory
      Thread.current[GITHUB_VALIDATOR_KEY] = previous_validator
      Thread.current[INPUT_KEY] = previous_input
    end

    def context_factory
      Thread.current[CONTEXT_FACTORY_KEY] || Context.method(:build)
    end

    def input
      Thread.current[INPUT_KEY] || $stdin
    end

    def github_validator
      Thread.current[GITHUB_VALIDATOR_KEY] || Valpo::Sources::GitHub::Validator.new
    end
  end
end
