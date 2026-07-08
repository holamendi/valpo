# frozen_string_literal: true

require "tempfile"
require "test_helper"

class ValpoConfigTest < Minitest::Test
  def test_loads_api_token_from_config_file
    file = Tempfile.new("valpo-config")
    file.write(<<~YAML)
      test:
        database_path: tmp/test.sqlite3
        api_host: 127.0.0.1
        api_port: 7092
        api_token: secret-token
        caddy_config_path: tmp/Caddyfile
        docker_network: valpo
        worker_poll_interval: 2
        app_port_start: 20000
        app_port_end: 29999
        healthcheck_timeout: 30
        deploy_drain_delay: 0
    YAML
    file.close

    config = Valpo::Config.load(path: file.path, env: "test")

    assert_equal "secret-token", config.api_token
  ensure
    file&.unlink
  end
end
