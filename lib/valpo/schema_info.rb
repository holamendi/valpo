# frozen_string_literal: true

require "digest"

module Valpo
  module SchemaInfo
    MIGRATIONS_PATH = File.join(Valpo.root, "db", "migrations")
    BOOTSTRAP_FILENAME = "001_bootstrap.rb"
    BOOTSTRAP_SHA256 = "9510d2f2f3d29a56ba8d44b3f33383448169a8f1a45c6d54cdf04a8c6d583d0e"
    MIGRATION_PATTERN = /\A(\d+)_([a-z0-9_]+)\.rb\z/

    module_function

    def current(db: Valpo::Database.connection)
      return 0 unless db.table_exists?(:schema_info)

      Integer(db[:schema_info].get(:version) || 0)
    end

    def latest(path: MIGRATIONS_PATH)
      versions(path:).last || 0
    end

    def versions(path: MIGRATIONS_PATH)
      migration_files(path).map { Integer(File.basename(it).match(MIGRATION_PATTERN)[1], 10) }
    end

    def validate_migrations!(path: MIGRATIONS_PATH)
      validate_bootstrap!(path:)
      found = versions(path:)
      expected = (1..(found.last || 0)).to_a
      return true if found == expected

      raise Valpo::ValidationError,
        "Migration versions must be contiguous from 001; found: #{found.map { format("%03d", it) }.join(", ")}"
    end

    def validate_bootstrap!(path: MIGRATIONS_PATH)
      bootstrap = File.join(path, BOOTSTRAP_FILENAME)
      raise Valpo::ValidationError, "Migration is missing: #{BOOTSTRAP_FILENAME}" unless File.file?(bootstrap)
      return true if Digest::SHA256.file(bootstrap).hexdigest == BOOTSTRAP_SHA256

      raise Valpo::ValidationError,
        "#{BOOTSTRAP_FILENAME} is frozen at the first public schema and must not be edited; add a new migration"
    end

    def migration_files(path)
      Dir[File.join(path, "*.rb")].sort.tap do |files|
        invalid = files.reject { File.basename(it).match?(MIGRATION_PATTERN) }
        unless invalid.empty?
          raise Valpo::ValidationError,
            "Invalid migration filenames: #{invalid.map { File.basename(it) }.join(", ")}"
        end
      end
    end
    private_class_method :migration_files
  end
end
