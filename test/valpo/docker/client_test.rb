# frozen_string_literal: true

require "test_helper"

class ValpoDockerClientTest < Minitest::Test
  def test_commands_are_explicit_arrays
    client = Valpo::Docker::Client.new(binary: "docker")

    assert_equal ["docker", "pull", "ghcr.io/example/app:latest"], client.pull_command("ghcr.io/example/app:latest")
    assert_equal ["docker", "image", "inspect", "ghcr.io/example/app:latest"], client.image_inspect_command("ghcr.io/example/app:latest")
    assert_equal ["docker", "image", "ls", "--all", "--no-trunc", "--format", "{{json .}}"], client.image_list_command
    assert_equal ["docker", "image", "rm", "valpo/acme/app:v1"], client.image_rm_command("valpo/acme/app:v1")
    assert_equal ["docker", "build", "--file", "/tmp/app/Dockerfile", "--tag", "valpo/acme/app:abc123", "/tmp/app"], client.build_command(dockerfile: "/tmp/app/Dockerfile", tag: "valpo/acme/app:abc123", context: "/tmp/app")
    assert_equal ["docker", "container", "inspect", "valpo-hello"], client.container_inspect_command("valpo-hello")
    assert_equal(
      ["docker", "container", "ls", "--all", "--filter", "label=valpo.owned=true", "--no-trunc", "--format", "{{json .}}"],
      client.container_list_command(all: true, filters: ["label=valpo.owned=true"])
    )
    assert_equal ["docker", "start", "valpo-hello"], client.start_command("valpo-hello")
    assert_equal ["docker", "update", "--restart", "unless-stopped", "valpo-hello"], client.update_restart_policy_command("valpo-hello", "unless-stopped")
    assert_equal(
      ["docker", "network", "create", "--label", "valpo.owned=true", "valpo"],
      client.network_create_command("valpo", labels: {"valpo.owned" => "true"})
    )
    assert_equal ["docker", "network", "inspect", "valpo"], client.network_inspect_command("valpo")
    assert_equal(
      ["docker", "volume", "create", "--label", "valpo.owned=true", "valpo-data"],
      client.volume_create_command("valpo-data", labels: {"valpo.owned" => "true"})
    )
    assert_equal ["docker", "volume", "rm", "--force", "valpo-data"], client.volume_rm_command("valpo-data", force: true)
    assert_equal(
      ["docker", "volume", "ls", "--filter", "label=valpo.owned=true", "--format", "{{.Name}}"],
      client.volume_list_command(filters: ["label=valpo.owned=true"])
    )
    assert_equal ["docker", "exec", "valpo-db", "pg_isready"], client.exec_command("valpo-db", "pg_isready")
  end

  def test_run_command_includes_sorted_options
    client = Valpo::Docker::Client.new

    command = client.run_command(
      name: "valpo-hello",
      image: "ghcr.io/example/hello:latest",
      network: "valpo",
      labels: {"valpo.release_id" => "r1", "valpo.project_id" => "p1"},
      env_file: "/tmp/valpo-env",
      ports: {8080 => 3000},
      volumes: {"valpo-data" => "/data"},
      restart_policy: "unless-stopped",
      log_driver: "local",
      log_options: {"max-size" => "10m", "max-file" => 3},
      entrypoint: "/cnb/lifecycle/launcher",
      command_args: ["bin/server"]
    )

    assert_equal [
      "docker", "run", "--detach", "--name", "valpo-hello", "--network", "valpo",
      "--restart", "unless-stopped",
      "--entrypoint", "/cnb/lifecycle/launcher",
      "--log-driver", "local",
      "--log-opt", "max-file=3", "--log-opt", "max-size=10m",
      "--label", "valpo.project_id=p1", "--label", "valpo.release_id=r1",
      "--env-file", "/tmp/valpo-env", "--publish", "8080:3000",
      "--volume", "valpo-data:/data",
      "ghcr.io/example/hello:latest", "bin/server"
    ], command
  end

  def test_run_container_keeps_environment_out_of_argv_and_deletes_private_file
    client = RecordingClient.new
    secret = "postgres://user:secret@example/database"

    result = client.run_container(
      name: "valpo-hello",
      image: "example/hello",
      network: "valpo",
      env: {"DATABASE_URL" => secret}
    )

    assert result.fetch(:success)
    refute_includes client.executed_command.join(" "), secret
    assert_equal "DATABASE_URL=#{secret}\n", client.environment
    assert_equal 0o600, client.mode
    refute File.exist?(client.environment_path)
  end

  def test_run_container_deletes_environment_file_when_execution_raises
    client = RecordingClient.new(error: RuntimeError.new("docker failed"))

    assert_raises(RuntimeError) do
      client.run_container(name: "valpo-hello", image: "example/hello", network: "valpo", env: {"TOKEN" => "secret"})
    end

    refute File.exist?(client.environment_path)
  end

  def test_run_container_rejects_environment_values_that_cannot_be_encoded_safely
    client = RecordingClient.new

    assert_raises(Valpo::ValidationError) do
      client.run_container(name: "valpo-hello", image: "example/hello", network: "valpo", env: {"TOKEN" => "one\ntwo"})
    end
    assert_raises(Valpo::ValidationError) do
      client.run_container(name: "valpo-hello", image: "example/hello", network: "valpo", env: {"BAD=KEY" => "value"})
    end
  end

  class RecordingClient < Valpo::Docker::Client
    attr_reader :executed_command, :environment, :environment_path, :mode

    def initialize(error: nil)
      super()
      @error = error
    end

    def execute(command)
      @executed_command = command
      @environment_path = command.fetch(command.index("--env-file") + 1)
      @environment = File.read(environment_path)
      @mode = File.stat(environment_path).mode & 0o777
      raise @error if @error

      {stdout: "container", stderr: "", status: 0, success: true}
    end
  end
end
