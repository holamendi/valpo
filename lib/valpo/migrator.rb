# frozen_string_literal: true

require "sequel"

module Valpo
  module Migrator
    Sequel.extension :migration

    MIGRATIONS_PATH = File.join(Valpo.root, "db", "migrations")

    def self.run(db: Valpo::Database.connection, path: MIGRATIONS_PATH, target: nil)
      reject_legacy_schema!(db)
      options = {}
      options[:target] = target if target
      Sequel::Migrator.run(db, path, **options)
    end

    def self.reject_legacy_schema!(db)
      return unless db.table_exists?(:projects)
      return unless db.schema(:projects).to_h.key?(:type)

      raise Valpo::ValidationError,
        "This pre-release Valpo database uses the retired project-as-app schema; back it up, remove it, and reinstall Valpo"
    end
    private_class_method :reject_legacy_schema!
  end
end
