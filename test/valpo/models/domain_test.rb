# frozen_string_literal: true

require "test_helper"

class ValpoDomainTest < Minitest::Test
  include ValpoTestDatabase

  def test_normalizes_hostname_for_web_service
    service = create_app_service
    domain = Valpo::Domain.create(service_id: service.id, hostname: "Hello.Example.COM")
    assert_equal "hello.example.com", domain.hostname
    assert_equal "unknown", domain.tls_status
    assert_match(/\Adom_[0-9a-f]{32}\z/, domain.id)
  end

  def test_validates_hostname
    service = create_app_service
    error = assert_raises Sequel::ValidationFailed do
      Valpo::Domain.create(service_id: service.id, hostname: "not a host")
    end
    assert_match "hostname", error.message
  end
end
