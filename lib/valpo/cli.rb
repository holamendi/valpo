# frozen_string_literal: true

require "dry/cli"

module Valpo
  module CLI
    DEFAULT_API_URL = "http://127.0.0.1:7092"
    DEFAULT_TIMEOUT = 600
    CONTEXT_FACTORY_KEY = :valpo_cli_context_factory
    GITHUB_VALIDATOR_KEY = :valpo_cli_github_validator
    API_CREDENTIAL_RECOVERY_FACTORY_KEY = :valpo_cli_api_credential_recovery_factory
    INPUT_KEY = :valpo_cli_input

    module_function

    def call(
      arguments = ARGV,
      out: $stdout,
      err: $stderr,
      input: $stdin,
      context_factory: nil,
      github_validator: nil,
      api_credential_recovery_factory: nil
    )
      previous_factory = Thread.current[CONTEXT_FACTORY_KEY]
      previous_validator = Thread.current[GITHUB_VALIDATOR_KEY]
      previous_recovery_factory = Thread.current[API_CREDENTIAL_RECOVERY_FACTORY_KEY]
      previous_input = Thread.current[INPUT_KEY]
      Thread.current[CONTEXT_FACTORY_KEY] = context_factory if context_factory
      Thread.current[GITHUB_VALIDATOR_KEY] = github_validator if github_validator
      if api_credential_recovery_factory
        Thread.current[API_CREDENTIAL_RECOVERY_FACTORY_KEY] = api_credential_recovery_factory
      end
      Thread.current[INPUT_KEY] = input
      Runner.new(out:, err:).call(arguments)
    ensure
      Thread.current[CONTEXT_FACTORY_KEY] = previous_factory
      Thread.current[GITHUB_VALIDATOR_KEY] = previous_validator
      Thread.current[API_CREDENTIAL_RECOVERY_FACTORY_KEY] = previous_recovery_factory
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

    def api_credential_recovery_factory
      Thread.current[API_CREDENTIAL_RECOVERY_FACTORY_KEY] || ->(config_path:) { Valpo::Credentials::Recovery.new(config_path:) }
    end
  end
end
