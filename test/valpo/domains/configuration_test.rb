# frozen_string_literal: true

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
end
