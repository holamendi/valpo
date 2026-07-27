# frozen_string_literal: true

require "fileutils"
require "sequel"
require "sequel/model"

module Valpo
  module Database
    BUSY_TIMEOUT_MS = 5000
    WAL_AUTOCHECKPOINT = 1000

    class << self
      attr_writer :connection

      def connect(config = Valpo::Config.load)
        FileUtils.mkdir_p(File.dirname(config.database_path))
        Sequel.default_timezone = :utc
        @connection = Sequel.sqlite(
          config.database_path,
          foreign_keys: true,
          synchronous: :normal,
          connect_sqls: [
            "PRAGMA auto_vacuum = INCREMENTAL",
            "PRAGMA journal_mode = WAL",
            "PRAGMA busy_timeout = #{BUSY_TIMEOUT_MS}",
            "PRAGMA wal_autocheckpoint = #{WAL_AUTOCHECKPOINT}"
          ]
        )
        @connection.transaction_mode = :immediate
        Sequel::Model.db = @connection
        @connection
      end

      def connection
        @connection ||= connect
      end

      def disconnect
        @connection&.disconnect
        @connection = nil
      end
    end
  end
end
