# frozen_string_literal: true

require "test_helper"

class ValpoDeploymentsPortResolverTest < Minitest::Test
  include ValpoTestDatabase

  def test_prefers_explicit_then_single_exposed_port
    service = create_app_service(port: nil)
    assert_equal 9292, resolve(service, explicit: 9292, exposed: [3000], source_type: "registry")
    assert_equal 8080, resolve(service, explicit: nil, exposed: [8080], source_type: "registry")
  end

  def test_source_build_without_exposed_port_uses_platform_fallback
    service = create_app_service(port: nil)
    assert_equal 3000, resolve(service, explicit: nil, exposed: [], source_type: "git")
  end

  def test_registry_requires_an_unambiguous_port
    service = create_app_service(port: nil)
    assert_match "does not expose", assert_raises(Valpo::ValidationError) {
      resolve(service, explicit: nil, exposed: [], source_type: "registry")
    }.message
    assert_match "multiple", assert_raises(Valpo::ValidationError) {
      resolve(service, explicit: nil, exposed: [3000, 9292], source_type: "git")
    }.message
  end

  def test_workers_have_no_port
    worker = create_app_service(name: "worker", kind: "worker", port: nil)
    assert_nil resolve(worker, explicit: nil, exposed: [3000], source_type: "registry")
  end

  private

  def resolve(service, explicit:, exposed:, source_type:)
    Valpo::Deployments::PortResolver.new.resolve(
      service:,
      explicit_port: explicit,
      source_type:,
      image_metadata: Valpo::Deployments::ImageMetadata.new(digest: nil, exposed_tcp_ports: exposed)
    )
  end
end
