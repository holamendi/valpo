# frozen_string_literal: true

require "test_helper"

class ValpoDockerClientTest < Minitest::Test
  def test_commands_are_explicit_arrays
    client = Valpo::Docker::Client.new(binary: "docker")

    assert_equal ["docker", "pull", "ghcr.io/example/app:latest"], client.pull_command("ghcr.io/example/app:latest")
    assert_equal ["docker", "image", "inspect", "ghcr.io/example/app:latest"], client.image_inspect_command("ghcr.io/example/app:latest")
    assert_equal ["docker", "build", "--file", "/tmp/app/Dockerfile", "--tag", "valpo/acme/app:abc123", "/tmp/app"], client.build_command(dockerfile: "/tmp/app/Dockerfile", tag: "valpo/acme/app:abc123", context: "/tmp/app")
    assert_equal ["docker", "container", "inspect", "valpo-hello"], client.container_inspect_command("valpo-hello")
    assert_equal ["docker", "start", "valpo-hello"], client.start_command("valpo-hello")
    assert_equal ["docker", "update", "--restart", "unless-stopped", "valpo-hello"], client.update_restart_policy_command("valpo-hello", "unless-stopped")
    assert_equal ["docker", "network", "create", "valpo"], client.network_create_command("valpo")
    assert_equal ["docker", "volume", "create", "valpo-data"], client.volume_create_command("valpo-data")
    assert_equal ["docker", "volume", "rm", "--force", "valpo-data"], client.volume_rm_command("valpo-data", force: true)
    assert_equal ["docker", "exec", "valpo-db", "pg_isready"], client.exec_command("valpo-db", "pg_isready")
  end

  def test_run_command_includes_sorted_options
    client = Valpo::Docker::Client.new

    command = client.run_command(
      name: "valpo-hello",
      image: "ghcr.io/example/hello:latest",
      network: "valpo",
      labels: {"valpo.release_id" => "r1", "valpo.project_id" => "p1"},
      env: {"RACK_ENV" => "production"},
      ports: {8080 => 3000},
      volumes: {"valpo-data" => "/data"},
      restart_policy: "unless-stopped",
      entrypoint: "/cnb/lifecycle/launcher",
      command_args: ["bin/server"]
    )

    assert_equal [
      "docker", "run", "--detach", "--name", "valpo-hello", "--network", "valpo",
      "--restart", "unless-stopped",
      "--entrypoint", "/cnb/lifecycle/launcher",
      "--label", "valpo.project_id=p1", "--label", "valpo.release_id=r1",
      "--env", "RACK_ENV=production", "--publish", "8080:3000",
      "--volume", "valpo-data:/data",
      "ghcr.io/example/hello:latest", "bin/server"
    ], command
  end
end
