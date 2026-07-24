# frozen_string_literal: true

require "sequel"

module Valpo
  module Migrator
    Sequel.extension :migration

    MIGRATIONS_PATH = File.join(Valpo.root, "db", "migrations")

    def self.run(db: Valpo::Database.connection, path: MIGRATIONS_PATH, target: nil)
      options = {}
      options[:target] = target if target
      Sequel::Migrator.run(db, path, **options)
    end
  end
end
