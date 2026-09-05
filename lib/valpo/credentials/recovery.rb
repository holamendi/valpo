# frozen_string_literal: true

module Valpo
  module Credentials
    class Recovery
      def initialize(config_path: nil)
        @config_path = config_path
      end

      def call(name:)
        config = config_path ? Valpo::Config.load(path: config_path) : Valpo::Config.load
        database = Valpo::Database.connect(config)
        Valpo::ReleaseMetadata.current.validate_database!(db: database)
        Valpo::APICredential.recover(name:)
      ensure
        Valpo::Database.disconnect if database
      end

      private

      attr_reader :config_path
    end
  end
end
