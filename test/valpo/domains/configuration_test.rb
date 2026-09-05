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
    assert_equal "hello-web.apps.example.com", domain.hostname
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

  def test_colliding_names_receive_distinct_stable_slugs
    create_platform_domain(hostname: "example.com")
    first = create_app_service(project: create_project(name: "a-b"), name: "c")
    second = create_app_service(project: create_project(name: "a"), name: "b-c")

    assert_equal "a-b-c", first.domain_slug
    assert_match(/\Aa-b-c-[0-9a-f]{8}\z/, second.domain_slug)
    second.update(name: "renamed")
    domain = Valpo::Domains::Configuration.reconcile_service(second)
    assert_equal "#{second.domain_slug}.example.com", domain.hostname
    assert_equal 1, second.domains_dataset.count
    assert_raises(Sequel::ValidationFailed) { second.update(domain_slug: "different") }
  end

  def test_custom_domain_collision_is_preserved
    service = create_app_service
    custom = create_domain(service:, hostname: "hello-web.example.com")
    platform = create_platform_domain(hostname: "example.com")

    domain = Valpo::Domains::Configuration.reconcile_service(service, platform_domain: platform)

    assert_match(/\Ahello-web-[0-9a-f]{8}\.example\.com\z/, domain.hostname)
    assert_equal "custom", custom.refresh.kind
    assert custom.verified?
  end

  def test_long_slugs_fit_a_single_dns_label_even_after_collision
    create_platform_domain(hostname: "example.com")
    project = create_project(name: "a" * 63)
    first = create_app_service(project:, name: "one")
    second = create_app_service(project:, name: "two")

    [first, second].each do
      assert_operator it.domain_slug.length, :<=, 63
      assert Valpo::Hostname.valid?(it.domains.first.hostname)
      assert_equal 3, it.domains.first.hostname.split(".").length
    end
    refute_equal first.domain_slug, second.domain_slug
  end

  def test_slug_survives_default_domain_change_and_old_domain_remains_until_verified
    create_platform_domain(hostname: "example.com")
    service = create_app_service
    old = service.domains.first
    platform, = Valpo::Domains::Configuration.stage("new.example.com")

    Valpo::Domains::Configuration.activate!(platform)

    assert_equal "hello-web", service.refresh.domain_slug
    assert_equal ["hello-web.example.com", "hello-web.new.example.com"], service.domains_dataset.order(:hostname).select_map(:hostname)
    assert old.refresh
  end

  def test_exhausted_random_collisions_roll_back_allocation
    service = create_app_service
    create_domain(service:, hostname: "hello-web.example.com")
    create_domain(service:, hostname: "hello-web-aaaaaaaa.example.com")
    platform = create_platform_domain(hostname: "example.com")

    SecureRandom.stub(:hex, "aaaaaaaa") do
      assert_raises(Valpo::ConflictError) do
        Valpo::Domains::Configuration.reconcile_service(service, platform_domain: platform)
      end
    end

    assert_nil service.refresh.domain_slug
    assert_equal 2, service.domains_dataset.count
  end

  def test_setting_existing_default_schedules_replacement_of_legacy_hostname
    service = create_app_service
    platform = create_platform_domain(hostname: "example.com")
    legacy = create_domain(service:, hostname: "web.hello.example.com", kind: "generated", platform_domain_id: platform.id)

    record, changed = Valpo::Domains::Configuration.stage("example.com")

    assert_equal platform.id, record.id
    assert changed
    assert legacy.refresh.verified?
    replacement = service.domains_dataset.where(hostname: "hello-web.example.com").first
    assert_equal "pending", replacement.status
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
    credentials = Valpo::GitHub::Credentials.new
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
