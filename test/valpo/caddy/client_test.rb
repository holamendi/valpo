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

  def test_write_and_restore_preserve_the_previous_file
    Dir.mktmpdir do
      path = File.join(it, "valpo.caddy")
      File.binwrite(path, "previous\n")
      File.chmod(0o640, path)
      client = Valpo::Caddy::Client.new(config_path: path)

      snapshot = client.write_config([
        {hostname: "hello.example.com", kind: "container", upstream: "127.0.0.1:20000"}
      ])
      refute_equal "previous\n", File.binread(path)

      client.restore_config(snapshot)

      assert_equal "previous\n", File.binread(path)
      assert_equal 0o640, File.stat(path).mode & 0o777
    end
  end

  def test_restore_removes_a_new_config_file
    Dir.mktmpdir do
      path = File.join(it, "valpo.caddy")
      client = Valpo::Caddy::Client.new(config_path: path)

      snapshot = client.write_config([])
      assert_path_exists path

      client.restore_config(snapshot)

      refute_path_exists path
    end
  end
end
