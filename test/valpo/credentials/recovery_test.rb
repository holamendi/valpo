# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "test_helper"
require "yaml"

class ValpoCredentialsRecoveryTest < Minitest::Test
  def test_recovers_one_admin_through_the_local_database
    Dir.mktmpdir("valpo-api-recovery") do
      path = File.join(it, "valpo.sqlite3")
      database = Sequel.sqlite(path)
      Valpo::Migrator.run(db: database)
      database.disconnect

      stdout, stderr, status = recover(path, "rescue-admin")

      assert status.success?, stderr
      assert_empty stderr
      result = JSON.parse(stdout)
      assert_equal "rescue-admin", result.fetch("name")
      assert_equal ["admin"], result.fetch("scopes")
      assert_match(/\Avalpo_/, result.fetch("token"))

      database = Sequel.sqlite(path)
      assert_equal 1, database[:api_credentials].count
      assert database[:control_plane_states].where(id: 1).get(:api_bootstrapped_at)
      database.disconnect

      _stdout, stderr, status = recover(path, "second-admin")
      refute status.success?
      assert_includes stderr, "An active admin API credential already exists"
    ensure
      database&.disconnect
    end
  end

  def test_uses_the_environment_config_when_no_option_is_passed
    Dir.mktmpdir("valpo-api-recovery-config") do
      database_path = File.join(it, "valpo.sqlite3")
      config_path = File.join(it, "valpo.yml")
      database = Sequel.sqlite(database_path)
      Valpo::Migrator.run(db: database)
      database.disconnect
      File.write(
        config_path,
        YAML.dump("production" => {"config_schema" => 1, "database_path" => database_path})
      )

      stdout, stderr, status = recover(nil, "configured-admin", config_path:)

      assert status.success?, stderr
      assert_empty stderr
      assert_equal "configured-admin", JSON.parse(stdout).fetch("name")
      database = Sequel.sqlite(database_path)
      assert_equal 1, database[:api_credentials].count
    ensure
      database&.disconnect
    end
  end

  private

  def recover(database_path, name, config_path: nil)
    Open3.capture3(
      {
        "VALPO_CONFIG" => config_path,
        "VALPO_DATABASE_PATH" => database_path,
        "VALPO_ENV" => config_path ? "production" : "test"
      },
      RbConfig.ruby,
      "-Ilib",
      "exe/valpo",
      "auth",
      "token",
      "recover",
      name,
      "--confirm-offline-recovery",
      "--json",
      chdir: Valpo.root
    )
  end
end
