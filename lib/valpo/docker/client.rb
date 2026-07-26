# frozen_string_literal: true

require "open3"

module Valpo
  module Docker
    class Client
      def initialize(binary: "docker")
        @binary = binary
      end

      def pull_command(image)
        command("pull", image)
      end

      def image_inspect_command(image)
        command("image", "inspect", image)
      end

      def build_command(dockerfile:, tag:, context:)
        command("build", "--file", dockerfile, "--tag", tag, context)
      end

      def run_command(name:, image:, network:, labels: {}, env: {}, ports: {}, volumes: {}, detach: true, restart_policy: nil, entrypoint: nil, command_args: [])
        args = ["run"]
        args << "--detach" if detach
        args += ["--name", name, "--network", network]
        args += ["--restart", restart_policy] if restart_policy
        args += ["--entrypoint", entrypoint] if entrypoint
        labels.sort.each { |key, value| args += ["--label", "#{key}=#{value}"] }
        env.sort.each { |key, value| args += ["--env", "#{key}=#{value}"] }
        ports.sort.each { |host, container| args += ["--publish", "#{host}:#{container}"] }
        volumes.sort.each { |source, target| args += ["--volume", "#{source}:#{target}"] }
        args << image
        args.concat(command_args)
        command(*args)
      end

      def container_inspect_command(name)
        command("container", "inspect", name)
      end

      def start_command(name)
        command("start", name)
      end

      def update_restart_policy_command(name, restart_policy)
        command("update", "--restart", restart_policy, name)
      end

      def stop_command(name)
        command("stop", name)
      end

      def rm_command(name, force: false)
        args = ["rm"]
        args << "--force" if force
        args << name
        command(*args)
      end

      def logs_command(name, follow: false, tail: nil)
        args = ["logs"]
        args << "--follow" if follow
        args += ["--tail", tail.to_s] if tail
        args << name
        command(*args)
      end

      def exec_command(name, *command_args)
        command("exec", name, *command_args)
      end

      def network_create_command(name)
        command("network", "create", name)
      end

      def network_inspect_command(name)
        command("network", "inspect", name)
      end

      def volume_create_command(name)
        command("volume", "create", name)
      end

      def volume_rm_command(name, force: false)
        args = ["volume", "rm"]
        args << "--force" if force
        args << name
        command(*args)
      end

      def execute(command)
        stdout, stderr, status = Open3.capture3(*command)
        {stdout:, stderr:, status: status.exitstatus, success: status.success?}
      end

      private

      attr_reader :binary

      def command(*args)
        [binary, *args]
      end
    end
  end
end
