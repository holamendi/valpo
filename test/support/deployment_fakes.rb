# frozen_string_literal: true

require "json"

module ValpoTestSupport
  class FakeDocker
    attr_reader :commands, :run_requests

    def initialize(fail_on: nil, container_states: {}, exposed_ports: [], network_exists: false, network_owned: true)
      @fail_on = fail_on
      @container_states = container_states
      @exposed_ports = exposed_ports
      @network_exists = network_exists
      @network_owned = network_owned
      @commands = []
      @run_requests = []
    end

    def pull_command(image)
      [:pull, image]
    end

    def image_inspect_command(image)
      [:inspect, image]
    end

    def run_command(name:, image:, network:, labels:, ports:, env: {}, volumes: {}, restart_policy: nil, entrypoint: nil, command_args: [], **)
      run_requests << {
        name:,
        image:,
        network:,
        labels:,
        env:,
        ports:,
        volumes:,
        restart_policy:,
        entrypoint:,
        command_args:
      }
      [:run, name]
    end

    def run_container(env: {}, **options)
      execute(run_command(**options, env:))
    end

    def network_create_command(name, labels: {})
      [:network_create, name]
    end

    def network_inspect_command(name)
      [:network_inspect, name]
    end

    def container_inspect_command(name)
      [:container_inspect, name]
    end

    def start_command(name)
      [:start, name]
    end

    def update_restart_policy_command(name, restart_policy)
      [:update_restart_policy, name, restart_policy]
    end

    def stop_command(name)
      [:stop, name]
    end

    def rm_command(name, force:)
      [:rm, name, force]
    end

    def logs_command(name, tail: nil, **)
      [:logs, name, tail]
    end

    def exec_command(name, *command_args)
      [:exec, name, *command_args]
    end

    def volume_create_command(name, labels: {})
      [:volume_create, name]
    end

    def volume_rm_command(name, force:)
      [:volume_rm, name, force]
    end

    def executed?(*command)
      commands.include?(command)
    end

    def execute(command)
      commands << command
      return failure("#{command.first} failed") if command.first == @fail_on
      return failure("network already exists") if command.first == :network_create && @network_exists

      case command.first
      when :inspect
        exposed = @exposed_ports.to_h { ["#{it}/tcp", {}] }
        success(JSON.generate([{
          "RepoDigests" => ["#{command.fetch(1)}@sha256:abc"],
          "Config" => {"ExposedPorts" => exposed}
        }]))
      when :container_inspect
        container_state = @container_states.fetch(command.fetch(1), true)
        return failure("No such object: #{command.fetch(1)}") if container_state == :missing

        success(JSON.generate([{"State" => {"Running" => container_state == true}}]))
      when :network_inspect
        labels = @network_owned ? {"valpo.owned" => "true"} : {}
        success(JSON.generate([{"Labels" => labels}]))
      when :logs
        success("app log\n")
      when :exec
        success("ready\n")
      else
        success("ok\n")
      end
    end

    private

    def success(stdout)
      {stdout:, stderr: "", status: 0, success: true}
    end

    def failure(stderr)
      {stdout: "", stderr:, status: 1, success: false}
    end
  end

  class FakeCaddy
    attr_reader :routes

    def initialize(fail_reload: false, fail_reloads: 0)
      @reload_failures = fail_reload ? Float::INFINITY : fail_reloads
    end

    def write_config(routes)
      previous = @routes
      @routes = routes
      previous
    end

    def restore_config(routes)
      @routes = routes
    end

    def reload_command
      [:reload_caddy]
    end

    def execute(_command)
      if @reload_failures.positive?
        @reload_failures -= 1
        return {stdout: "", stderr: "reload failed", status: 1, success: false}
      end

      {stdout: "reloaded\n", stderr: "", status: 0, success: true}
    end
  end

  class FakeHealthChecker
    def wait(route_target:, path:, timeout:)
      @route_target = route_target
      @path = path
      @timeout = timeout
      true
    end
  end

  class FakeDomainVerifier
    attr_reader :requests

    def initialize(error: nil, fail_for: nil)
      @error = error
      @fail_for = fail_for
      @requests = []
    end

    def verify!(hostname:, token:)
      requests << {hostname:, token:}
      raise @error if @error && (!@fail_for || @fail_for.call(hostname))

      true
    end
  end
end
