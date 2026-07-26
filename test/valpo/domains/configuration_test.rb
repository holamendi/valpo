# frozen_string_literal: true

require "openssl"
require "test_helper"

class ValpoDomainsConfigurationTest < Minitest::Test
  include ValpoTestDatabase

  def test_stages_and_activates_app_domain_then_backfills_web_services
    service = create_app_service
    record, changed = Valpo::Domains::Configuration.stage("Apps.Example.COM.")

    assert changed
    assert_equal "apps.example.com", record.hostname
    assert_equal "pending", record.status
    assert_nil Valpo::Domain.where(service_id: service.id).first

    Valpo::Domains::Configuration.activate!(record)

    domain = Valpo::Domain.where(service_id: service.id).first
    assert_equal "web.hello.apps.example.com", domain.hostname
    assert_equal "generated", domain.kind
    assert_equal "pending", domain.status
    assert_equal record.id, domain.platform_domain_id
  end

  def test_rejects_wildcard_syntax
    error = assert_raises Valpo::ValidationError do
      Valpo::Domains::Configuration.stage("*.apps.example.com")
    end

    assert_match "without *.", error.message
  end

  def test_github_integration_hostname_is_reserved
    create_platform_domain
    service = create_app_service

    error = assert_raises Sequel::ValidationFailed do
      Valpo::Domain.create(service_id: service.id, hostname: "github.apps.example.com")
    end

    assert_match "reserved for the GitHub integration", error.message
  end

  def test_app_domain_cannot_change_during_github_app_setup
    create_platform_domain
    Valpo::GitHubAppSetup.create(
      state_digest: "a" * 64,
      app_domain: "apps.example.com",
      expires_at: Time.now.utc + 60
    )

    error = assert_raises Valpo::ConflictError do
      Valpo::Domains::Configuration.stage("new.example.com")
    end

    assert_match "GitHub App setup", error.message
  end

  def test_app_domain_cannot_change_while_github_app_credentials_use_it
    create_platform_domain
    credentials = Valpo::GitHub::Credentials.new(Valpo.config.github_app_credentials_path)
    credentials.write(
      "app_id" => "123",
      "app_domain" => "apps.example.com",
      "client_id" => "Iv1.client",
      "owner" => "octocat",
      "slug" => "valpo-test",
      "pem" => OpenSSL::PKey::RSA.generate(1024).to_pem,
      "webhook_secret" => "hook-secret"
    )

    error = assert_raises Valpo::ConflictError do
      Valpo::Domains::Configuration.stage("new.example.com")
    end

    assert_match "Remove local GitHub authentication", error.message
  ensure
    credentials&.delete
  end
end
