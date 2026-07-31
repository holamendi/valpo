# frozen_string_literal: true

module Valpo
  module Boot
    def self.run(config: Valpo::Config.load, migrate: false)
      Valpo.config = config
      keyring = Valpo::Secrets::Keyring.new(config.encryption_key_path)
      keyring.active_version
      Valpo.secrets = Valpo::Secrets::Cipher.new(
        keyring:
      )
      Valpo::Database.connect(config)
      Valpo::Migrator.run if migrate
      Valpo::ReleaseMetadata.current.validate_database!
      Valpo::InstallationMetadata.current
      validate_config!(config)
      Valpo::Database.connection
    end

    def self.validate_config!(config)
      validate_api_binding!(config)
    end

    def self.validate_api_binding!(config)
      return if local_api_host?(config.api_host)
      return if Valpo::APICredential.active.count.positive?

      raise Valpo::ValidationError, "At least one active API credential is required when api_host is not local"
    end
    private_class_method :validate_api_binding!

    def self.local_api_host?(host)
      %w[127.0.0.1 localhost ::1].include?(host.to_s)
    end
    private_class_method :local_api_host?
  end
end
