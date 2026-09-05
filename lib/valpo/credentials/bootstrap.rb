# frozen_string_literal: true

module Valpo
  module Credentials
    class Bootstrap
      def initialize(config_path: nil)
        @config_path = config_path
      end

      def call
        config = config_path ? Valpo::Config.load(path: config_path) : Valpo::Config.load
        database = Valpo::Database.connect(config)
        Valpo::ReleaseMetadata.current.validate_database!(db: database)
        database.transaction(mode: :immediate) do
          next if Valpo::ControlPlaneState.api_bootstrapped?

          _credential, token = Valpo::APICredential.bootstrap(name: "initial-admin")
          token
        end
      ensure
        Valpo::Database.disconnect if database
      end

      private

      attr_reader :config_path
    end
  end
end
