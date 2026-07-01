# frozen_string_literal: true

require "test_helper"

class ValpoCaddyClientTest < Minitest::Test
  def test_exposes_reload_command
    client = Valpo::Caddy::Client.new(config_path: "/etc/caddy/valpo.caddy")

    assert_equal ["caddy", "reload", "--config", "/etc/caddy/valpo.caddy"], client.reload_command
  end

  def test_reload_command_can_use_main_caddyfile
    client = Valpo::Caddy::Client.new(
      config_path: "/var/lib/valpo/caddy/valpo.caddy",
      reload_config_path: "/etc/caddy/Caddyfile"
    )

    assert_equal ["caddy", "reload", "--config", "/etc/caddy/Caddyfile"], client.reload_command
  end
end
