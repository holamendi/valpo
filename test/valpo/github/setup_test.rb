# frozen_string_literal: true

require "fileutils"
require "openssl"
require "test_helper"
require "uri"

class ValpoGitHubSetupTest < Minitest::Test
  include ValpoTestDatabase

  def test_creates_a_one_time_manifest_and_persists_the_conversion
    create_platform_domain
    path = File.join(VALPO_TEST_DIR, "github-setup", "app.json")
    credentials = Valpo::GitHub::Credentials.new(path)
    client = FakeClient.new(converted_credentials)
    now = Time.utc(2026, 7, 26, 12)
    setup = Valpo::GitHub::Setup.new(
      credentials:,
      client:,
      clock: -> { now }
    )

    started = setup.start(organization: "acme")
    uri = URI(started.fetch("setup_url"))
    token = URI.decode_www_form(uri.query).to_h.fetch("token")
    form = setup.form(token)
    manifest = form.fetch(:manifest)
    completed = setup.complete(code: "github-code", state: token)

    assert_equal "github.apps.example.com", uri.host
    assert_equal "acme", form.fetch(:organization)
    assert_equal "https://github.apps.example.com/integrations/github/webhook", manifest.dig(:hook_attributes, :url)
    assert_equal ["push"], manifest.fetch(:default_events)
    assert_equal({contents: "read"}, manifest.fetch(:default_permissions))
    assert_equal "github-code", client.converted_code
    assert_equal "valpo-test", credentials.read.fetch("slug")
    assert_equal "apps.example.com", credentials.read.fetch("app_domain")
    assert_equal "https://github.com/apps/valpo-test/installations/new", completed.fetch("install_url")
    assert_equal "completed", Valpo::GitHubAppSetup.first.status
  ensure
    FileUtils.rm_f(path) if path
  end

  def test_requires_a_verified_app_domain_and_rejects_expired_state
    setup = Valpo::GitHub::Setup.new(
      credentials: FakeCredentials.new,
      client: FakeClient.new(converted_credentials)
    )

    error = assert_raises Valpo::ValidationError do
      setup.start
    end
    assert_match "default app domain", error.message

    create_platform_domain
    now = Time.utc(2026, 7, 26, 12)
    setup = Valpo::GitHub::Setup.new(
      credentials: FakeCredentials.new,
      client: FakeClient.new(converted_credentials),
      clock: -> { now }
    )
    uri = URI(setup.start.fetch("setup_url"))
    token = URI.decode_www_form(uri.query).to_h.fetch("token")
    now += Valpo::GitHub::Setup::SETUP_TTL + 1

    error = assert_raises Valpo::ValidationError do
      setup.form(token)
    end
    assert_match "invalid or expired", error.message
  end

  def test_rejects_invalid_organization_names
    create_platform_domain
    setup = Valpo::GitHub::Setup.new(
      credentials: FakeCredentials.new,
      client: FakeClient.new(converted_credentials)
    )

    error = assert_raises Valpo::ValidationError do
      setup.start(organization: "not/an/organization")
    end

    assert_match "GitHub organization", error.message
    assert_equal 0, Valpo::GitHubAppSetup.count
  end

  private

  def converted_credentials
    {
      "app_id" => "123",
      "client_id" => "Iv1.client",
      "owner" => "octocat",
      "slug" => "valpo-test",
      "pem" => OpenSSL::PKey::RSA.generate(1024).to_pem,
      "webhook_secret" => "hook-secret"
    }
  end

  class FakeClient
    attr_reader :converted_code

    def initialize(values)
      @values = values
    end

    def convert_manifest(code)
      @converted_code = code
      @values
    end
  end

  class FakeCredentials
    def configured?
      false
    end
  end
end
