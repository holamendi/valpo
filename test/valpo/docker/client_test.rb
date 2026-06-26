# frozen_string_literal: true

require "test_helper"

class ValpoDockerClientTest < Minitest::Test
  def test_commands_are_explicit_arrays
    client = Valpo::Docker::Client.new(binary: "docker")

    assert_equal ["docker", "pull", "ghcr.io/example/app:latest"], client.pull_command("ghcr.io/example/app:latest")
    assert_equal ["docker", "image", "inspect", "ghcr.io/example/app:latest"], client.image_inspect_command("ghcr.io/example/app:latest")
    assert_equal ["docker", "network", "create", "valpo"], client.network_create_command("valpo")
    assert_equal ["docker", "volume", "create", "valpo-data"], client.volume_create_command("valpo-data")
  end

  def test_run_command_includes_sorted_options
    client = Valpo::Docker::Client.new

    command = client.run_command(
      name: "valpo-hello",
      image: "ghcr.io/example/hello:latest",
      network: "valpo",
      labels: { "valpo.release_id" => "r1", "valpo.project_id" => "p1" },
      env: { "RACK_ENV" => "production" },
      ports: { 8080 => 3000 }
    )

    assert_equal [
      "docker", "run", "--detach", "--name", "valpo-hello", "--network", "valpo",
      "--label", "valpo.project_id=p1", "--label", "valpo.release_id=r1",
      "--env", "RACK_ENV=production", "--publish", "8080:3000",
      "ghcr.io/example/hello:latest"
    ], command
  end
end
