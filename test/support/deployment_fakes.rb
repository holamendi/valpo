# frozen_string_literal: true

require "json"

module ValpoTestSupport
  class FakeDocker
    attr_reader :commands, :run_requests

    def initialize(fail_on: nil, container_states: {})
      @fail_on = fail_on
      @container_states = container_states
      @commands = []
      @run_requests = []
    end

    def pull_command(image)
      [:pull, image]
    end

    def image_inspect_command(image)
      [:inspect, image]
    end

    def run_command(name:, image:, network:, labels:, ports:, restart_policy: nil, **)
      run_requests << {
        name: name,
        image: image,
        network: network,
        labels: labels,
        ports: ports,
        restart_policy: restart_policy
      }
      [:run, name]
    end

    def network_create_command(name)
      [:network_create, name]
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

    def executed?(*command)
      commands.include?(command)
    end

    def execute(command)
      commands << command
      return failure("#{command.first} failed") if command.first == @fail_on

      case command.first
      when :inspect
        success(JSON.generate([{"RepoDigests" => ["#{command.fetch(1)}@sha256:abc"]}]))
      when :container_inspect
        container_state = @container_states.fetch(command.fetch(1), true)
        return failure("No such object: #{command.fetch(1)}") if container_state == :missing

        success(JSON.generate([{"State" => {"Running" => container_state == true}}]))
      when :logs
        success("app log\n")
      else
        success("ok\n")
      end
    end

    private

    def success(stdout)
      {stdout: stdout, stderr: "", status: 0, success: true}
    end

    def failure(stderr)
      {stdout: "", stderr: stderr, status: 1, success: false}
    end
  end

  class FakeCaddy
    attr_reader :routes

    def write_config(routes)
      @routes = routes
    end

    def reload_command
      [:reload_caddy]
    end

    def execute(_command)
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
end
