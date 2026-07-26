# frozen_string_literal: true

require "test_helper"

class ValpoCaddyReconcilerTest < Minitest::Test
  include ValpoTestDatabase

  def test_active_app_domain_publishes_only_the_github_integration_prefix
    create_platform_domain
    caddy = ValpoTestSupport::FakeCaddy.new

    Valpo::Caddy::Reconciler.new(caddy:, config: VALPO_TEST_CONFIG).apply

    assert_includes caddy.routes, {
      hostname: "github.apps.example.com",
      kind: "restricted_proxy",
      upstream: "127.0.0.1:7092",
      path: "/integrations/github"
    }
  end

  def test_failed_reload_restores_the_previous_config
    previous = [
      {hostname: "old.example.com", kind: "container", upstream: "127.0.0.1:20000"}
    ]
    caddy = ValpoTestSupport::FakeCaddy.new(fail_reload: true)
    caddy.write_config(previous)

    error = assert_raises Valpo::ValidationError do
      Valpo::Caddy::Reconciler.new(caddy:, config: VALPO_TEST_CONFIG).apply
    end

    assert_match "Caddy reload failed", error.message
    assert_equal previous, caddy.routes
  end
end
