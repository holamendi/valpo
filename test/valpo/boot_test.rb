# frozen_string_literal: true

require "test_helper"

class ValpoBootTest < Minitest::Test
  include ValpoTestDatabase

  def test_non_local_api_host_requires_an_active_api_credential
    config = config_with(api_host: "0.0.0.0")

    error = assert_raises Valpo::ValidationError do
      validate_api_binding(config)
    end

    assert_match "active API credential", error.message
  end

  def test_non_local_api_host_allows_an_active_api_credential
    Valpo::APICredential.issue(name: "operator")
    config = config_with(api_host: "0.0.0.0")

    assert_silent { validate_api_binding(config) }
  end

  private

  def validate_api_binding(config)
    Valpo::Boot.validate_config!(config)
  end

  def config_with(api_host:)
    Valpo::Config.new(
      env: "test",
      root: Valpo.root,
      database_path: VALPO_TEST_CONFIG.database_path,
      api_host:,
      api_port: VALPO_TEST_CONFIG.api_port,
      caddy_config_path: VALPO_TEST_CONFIG.caddy_config_path,
      caddy_reload_config_path: VALPO_TEST_CONFIG.caddy_reload_config_path,
      docker_network: VALPO_TEST_CONFIG.docker_network,
      worker_poll_interval: VALPO_TEST_CONFIG.worker_poll_interval,
      app_port_start: VALPO_TEST_CONFIG.app_port_start,
      app_port_end: VALPO_TEST_CONFIG.app_port_end,
      healthcheck_timeout: VALPO_TEST_CONFIG.healthcheck_timeout,
      deploy_drain_delay: VALPO_TEST_CONFIG.deploy_drain_delay
    )
  end
end
