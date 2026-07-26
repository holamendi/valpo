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
end
