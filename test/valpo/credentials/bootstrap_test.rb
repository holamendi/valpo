# frozen_string_literal: true

require "open3"
require "rbconfig"
require "test_helper"

class ValpoCredentialsBootstrapTest < Minitest::Test
  def test_initial_credential_is_issued_once_and_never_reopens_after_revocation
    Dir.mktmpdir("valpo-bootstrap") do
      path = File.join(it, "valpo.sqlite3")
      database = Sequel.sqlite(path)
      Valpo::Migrator.run(db: database)

      token, stderr, status = bootstrap(path)
      assert status.success?, stderr
      assert_empty stderr
      assert_match(/\Avalpo_[A-Za-z0-9_-]+={0,2}\n\z/, token)
      credential = database[:api_credentials].first
      assert_equal "initial-admin", credential[:name]
      assert_equal Valpo::APICredential.digest(token.strip), credential[:token_digest]
      assert database[:control_plane_states].where(id: 1).get(:api_bootstrapped_at)

      output, stderr, status = bootstrap(path)
      assert status.success?, stderr
      assert_empty output
      assert_equal 1, database[:api_credentials].count
      database[:api_credentials].update(revoked_at: Time.now.utc)
      output, stderr, status = bootstrap(path)
      assert status.success?, stderr
      assert_empty output
      assert_equal 1, database[:api_credentials].count
    ensure
      database&.disconnect
    end
  end

  private

  def bootstrap(path)
    Open3.capture3(
      {"VALPO_CONFIG" => nil, "VALPO_DATABASE_PATH" => path, "VALPO_ENV" => "test"},
      RbConfig.ruby, "exe/valpo-bootstrap", chdir: Valpo.root
    )
  end
end
