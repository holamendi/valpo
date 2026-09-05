# frozen_string_literal: true

require "test_helper"

class ValpoDomainTest < Minitest::Test
  include ValpoTestDatabase

  def test_normalizes_hostname_for_web_service
    service = create_app_service
    domain = Valpo::Domain.create(service_id: service.id, hostname: "Hello.Example.COM")
    assert_equal "hello.example.com", domain.hostname
    assert_equal "custom", domain.kind
    assert_equal "pending", domain.status
    assert_match(/\Adom_[0-9a-f]{32}\z/, domain.id)
  end

  def test_validates_hostname
    service = create_app_service
    error = assert_raises Sequel::ValidationFailed do
      Valpo::Domain.create(service_id: service.id, hostname: "not a host")
    end
    assert_match "hostname", error.message
  end

  def test_domain_transitions_allow_verification_and_reject_unknown_edges
    service = create_app_service
    domain = Valpo::Domain.create(service_id: service.id, hostname: "hello.example.com")

    assert_equal "verified", domain.transition_to!("verified", verified_at: Time.now.utc).status
    assert_equal "pending", domain.transition_to!("pending", verified_at: nil).status
    error = assert_raises(Valpo::ValidationError) { domain.transition_to!("retired") }
    assert_equal "Forbidden domain transition from pending to retired", error.message
  end
end
