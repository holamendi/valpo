# frozen_string_literal: true

require "test_helper"

class ValpoCaddyClientTest < Minitest::Test
  def test_exposes_reload_command
    client = Valpo::Caddy::Client.new(config_path: "/etc/caddy/valpo.caddy")

    assert_equal ["caddy", "reload", "--config", "/etc/caddy/valpo.caddy"], client.reload_command
  end
end
