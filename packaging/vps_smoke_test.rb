# frozen_string_literal: true

require "json"
require "open3"
require "optparse"
require "securerandom"
require "shellwords"
require "time"

class VPSSmokeTest
  SERVICES = %w[docker caddy valpo-api valpo-worker valpo-maintenance.timer].freeze
  MANAGED_SECRET_NAMES = %w[DATABASE_URL PGPASSWORD REDIS_URL REDIS_PASSWORD].freeze
  REMOTE_RUBY = [
    "runuser", "-u", "valpo", "--", "env",
    "HOME=/var/lib/valpo",
    "USER=valpo",
    "PATH=/var/lib/valpo/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "MISE_RUBY_COMPILE=false",
    "MISE_YES=1",
    "/var/lib/valpo/.local/bin/mise", "x", "ruby@4.0.5", "--", "ruby"
  ].freeze

  Result = Data.define(:stdout, :stderr, :status) do
    def success?
      status.success?
    end
  end

  class CommandFailed < StandardError
    attr_reader :result

    def initialize(argv, result)
      @result = result
      super("Command failed (#{result.status.exitstatus}): #{argv.join(" ")}")
    end
  end

  class Runner
    def run(argv, input: nil, capture: false, allow_failure: false)
      stdout_buffer = +""
      stderr_buffer = +""
      status = nil

      Open3.popen3(*argv) do |stdin, stdout, stderr, wait_thread|
        writer = Thread.new do
          stdin.write(input) if input
        ensure
          stdin.close
        end
        stdout_reader = reader(stdout, stdout_buffer, $stdout, capture:)
        stderr_reader = reader(stderr, stderr_buffer, $stderr, capture:)
        writer.value
        stdout_reader.value
        stderr_reader.value
        status = wait_thread.value
      end

      result = Result.new(stdout: stdout_buffer, stderr: stderr_buffer, status:)
      raise CommandFailed.new(argv, result) unless allow_failure || result.success?

      result
    end

    private

    def reader(stream, buffer, destination, capture:)
      Thread.new do
        stream.each_line do
          buffer << it
          destination.write(it) unless capture
        end
      end
    end
  end

  class Remote
    attr_accessor :api_token

    def initialize(target, runner:)
      @target = target
      @runner = runner
    end

    def run(script, capture: false, allow_failure: false, auth: true, connect_timeout: nil)
      lines = ["set -euo pipefail"]
      lines << "export VALPO_API_TOKEN=#{Shellwords.escape(api_token)}" if auth && api_token
      lines << script
      argv = ["ssh"]
      argv.concat(["-o", "ConnectTimeout=#{connect_timeout}"]) if connect_timeout
      argv.concat([target, "bash -s"])
      runner.run(argv, input: "#{lines.join("\n")}\n", capture:, allow_failure:)
    end

    def capture(script, **options)
      run(script, capture: true, **options).stdout
    end

    def success?(script, **options)
      run(script, capture: true, allow_failure: true, **options).success?
    end

    private

    attr_reader :target, :runner
  end

  Options = Data.define(
    :ssh_target,
    :domain_suffix,
    :source_dir,
    :remote_source,
    :install_mode,
    :reboot,
    :project
  )

  def self.parse(argv)
    repo_root = File.expand_path("..", __dir__)
    values = {
      source_dir: repo_root,
      remote_source: "/tmp/valpo-src",
      install_mode: :full,
      reboot: false,
      project: "valpo-smoke-#{Time.now.utc.strftime("%Y%m%d%H%M%S")}"
    }
    parser = OptionParser.new do |options|
      options.banner = "Usage: packaging/vps-smoke-test.sh USER@HOST DOMAIN_SUFFIX [options]"
      options.separator ""
      options.separator "Runs a repeatable Valpo VPS smoke test over SSH."
      options.separator ""
      options.separator "Options:"
      options.on("--source PATH", "Source checkout to copy. Default: repository root.") do
        values[:source_dir] = File.expand_path(it)
      end
      options.on("--remote-source PATH", "Remote source path. Default: /tmp/valpo-src.") do
        values[:remote_source] = it
      end
      options.on("--full-install", "Run the installer with dependencies (default).") do
        values[:install_mode] = :full
      end
      options.on("--skip-deps", "Reuse dependencies already installed on the host.") do
        values[:install_mode] = :skip_deps
      end
      options.on("--reboot", "Reboot the VPS and verify the app returns.") do
        values[:reboot] = true
      end
      options.on("--project NAME", "Use a specific project name.") do
        values[:project] = it
      end
      options.on("-h", "--help", "Show this help.") do
        puts options
        exit
      end
    end
    parser.parse!(argv)
    raise OptionParser::MissingArgument, "USER@HOST and DOMAIN_SUFFIX are required" unless argv.length == 2

    Options.new(ssh_target: argv.fetch(0), domain_suffix: argv.fetch(1), **values)
  rescue OptionParser::ParseError => e
    warn e.message
    warn parser
    exit 64
  end

  def initialize(options, runner: Runner.new)
    @options = options
    @runner = runner
    @remote = Remote.new(options.ssh_target, runner:)
    @domain = "web.#{options.project}.#{options.domain_suffix}"
    @service_ids = {}
    @project_id = nil
    @api_credential_id = nil
    @project_touched = false
    @manifest_path = "/tmp/valpo-smoke-#{SecureRandom.hex(8)}.toml"
  end

  def run
    failure = nil
    begin
      smoke
    rescue => e
      failure = e
    ensure
      begin
        cleanup
      rescue => cleanup_error
        warn "[smoke] cleanup failed: #{cleanup_error.message}"
        failure ||= cleanup_error
      end
    end
    raise failure if failure

    puts "[smoke] ok"
  end

  private

  attr_reader :options, :runner, :remote, :domain, :service_ids

  def smoke
    puts "[smoke] target=#{options.ssh_target}"
    puts "[smoke] project=#{options.project}"
    puts "[smoke] domain=#{domain}"

    copy_source
    install_valpo
    verify_services
    configure_domain
    apply_manifest
    deploy_web
    load_service_ids
    verify_managed_services
    set_custom_secret
    verify_host_key_rotation
    unset_custom_secret
    verify_domain_and_https
    check_releases_and_logs
    reboot_and_verify if options.reboot
    verify_bound_project_delete
    delete_resources
    verify_cleanup!
  end

  def copy_source
    puts "[smoke] copying source"
    runner.run([
      "rsync", "-az", "--delete",
      "--exclude", ".git",
      "--exclude", "vendor/bundle",
      "--exclude", "tmp",
      "#{options.source_dir}/",
      "#{options.ssh_target}:#{options.remote_source}/"
    ])
  end

  def install_valpo
    puts "[smoke] installing Valpo"
    installer = "#{q(options.remote_source)}/packaging/install.sh"
    if options.install_mode == :skip_deps
      remote.run("VALPO_INSTALL_SKIP_DEPS=1 #{installer}")
    else
      remote.run(installer)
    end
  end

  def verify_services
    puts "[smoke] verifying services"
    remote.run("systemctl is-active #{SERVICES.map { q(it) }.join(" ")}")
    remote.run("curl -fsS http://127.0.0.1:7092/health")
    remote.run(<<~SH)
      test -f /var/lib/valpo/secrets/master.key
      test "$(stat -c '%a' /var/lib/valpo/secrets/master.key)" = 600
      test "$(sysctl -n vm.overcommit_memory)" = 1
      grep -Fx 'vm.overcommit_memory = 1' /etc/sysctl.d/99-valpo-redis.conf >/dev/null
    SH
  end

  def configure_domain
    puts "[smoke] configuring app domain"
    remote.run("valpo domain set-default #{q(options.domain_suffix)} --timeout 180")
  end

  def apply_manifest
    puts "[smoke] applying project manifest"
    manifest = <<~TOML
      schema = 1
      [project]
      name = #{options.project.inspect}
      [services.web]
      type = "web"
      port = 80
      healthcheck = "/"
      depends_on = ["database", "cache"]
      [services.database]
      type = "postgres"
      version = "18"
      [services.cache]
      type = "redis"
      version = "8"
    TOML
    encoded = [manifest].pack("m0")
    remote.run(<<~SH)
      umask 077
      rm -f #{q(@manifest_path)}
      printf %s #{q(encoded)} | base64 -d > #{q(@manifest_path)}
      chown valpo:valpo #{q(@manifest_path)}
      chmod 0600 #{q(@manifest_path)}
    SH
    remote.run("valpo project apply #{q(@manifest_path)} --dry-run")
    @project_touched = true
    remote.run("valpo project apply #{q(@manifest_path)} --timeout 600")
    project = remote_json("valpo project show #{q(options.project)} --json")
    puts JSON.pretty_generate(project)
    @project_id = project.fetch("id")
  end

  def deploy_web
    puts "[smoke] deploying nginx"
    remote.run(
      "valpo service deploy web --project #{q(options.project)} " \
      "--image nginx:alpine --timeout 300"
    )
  end

  def load_service_ids
    %w[web database cache].each do
      service_ids[it] = remote_json(
        "valpo service show #{q(it)} --project #{q(options.project)} --json"
      ).fetch("id")
    end
  end

  def verify_managed_services
    puts "[smoke] verifying managed services"
    remote.run("valpo service list --project #{q(options.project)}")
    %w[database cache].each do
      remote.run("valpo service show #{q(it)} --project #{q(options.project)}")
      remote.run("valpo service logs #{q(it)} --project #{q(options.project)} --tail 50")
    end

    environment_output = remote.capture(
      "valpo service env list web --project #{q(options.project)}"
    )
    puts environment_output
    MANAGED_SECRET_NAMES.each do |name|
      line = environment_output.lines.find { it.split.first == name }
      raise "#{name} was not redacted" unless line&.include?("********")
    end
    raise "Managed credential value leaked into smoke-test output" if environment_output.match?(/postgres(?:ql)?:\/\/|redis:\/\//)

    names = MANAGED_SECRET_NAMES.map { q(it) }.join(" ")
    remote.run(<<~SH)
      redacted_output="$(valpo service env list web --project #{q(options.project)})"
      revealed_output="$(valpo service env list web --project #{q(options.project)} --reveal)"
      for secret_name in #{names}; do
        secret_value="$(printf '%s\n' "$revealed_output" | awk -v name="$secret_name" '$1 == name { print $2; exit }')"
        test -n "$secret_value"
        if printf '%s\n' "$redacted_output" | grep -F -- "$secret_value" >/dev/null; then
          printf 'Credential value leaked for %s\n' "$secret_name" >&2
          exit 1
        fi
      done
    SH
    remote.run(<<~SH)
      container="$(docker ps --filter #{q("label=valpo.service_id=#{service_ids.fetch("web")}")} --format '{{.Names}}' | head -n 1)"
      test -n "$container"
      docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' |
        grep -E 'DATABASE_URL=|REDIS_URL=' >/dev/null
    SH
  end

  def set_custom_secret
    puts "[smoke] verifying encrypted custom service environment"
    @custom_secret = "valpo-smoke-secret-#{options.project}"
    remote.run(
      "printf %s #{q(@custom_secret)} | " \
      "valpo service env set web SMOKE_SECRET --project #{q(options.project)} --timeout 180"
    )
    remote.run(
      "valpo service env list web --project #{q(options.project)} | " \
      "grep -F SMOKE_SECRET | grep -F '********' >/dev/null"
    )
    remote.run(
      "valpo service env list web --project #{q(options.project)} --reveal | " \
      "grep -F #{q(@custom_secret)} >/dev/null"
    )
    remote.run(<<~SH)
      if grep -aF -- #{q(@custom_secret)} /var/lib/valpo/valpo.db* >/dev/null; then
        echo 'Custom environment plaintext leaked into SQLite' >&2
        exit 1
      fi
    SH
    remote.run(container_environment_assertion("SMOKE_SECRET=#{@custom_secret}"))
  end

  def verify_host_key_rotation
    puts "[smoke] creating temporary admin credential"
    credential = remote_json(
      "valpo auth token create #{q("smoke-#{options.project}")} --scope=admin --json",
      auth: false
    )
    @api_credential_id = credential.fetch("id")
    remote.api_token = credential.fetch("token")

    before = keyring_state
    puts "[smoke] verifying host-key rotation"
    remote.run("valpo system secrets verify --timeout 180")
    remote.run("valpo system secrets rotate --timeout 180")
    remote.run("valpo system secrets verify --timeout 180")
    after = keyring_state(previous_version: before.fetch("active"))
    unless after.fetch("active") == before.fetch("active") + 1
      raise "Host-key rotation did not advance exactly one version"
    end
    raise "Host-key rotation discarded the previous key" unless after.fetch("previous_key_present")

    remote.run(
      "valpo service env list web --project #{q(options.project)} --reveal | " \
      "grep -F #{q(@custom_secret)} >/dev/null"
    )
    remote.run("valpo service restart cache --project #{q(options.project)} --timeout 180")
    remote.run(
      "valpo service show cache --project #{q(options.project)} | grep -F running >/dev/null"
    )
  end

  def keyring_state(previous_version: nil)
    ruby = <<~RUBY
      values = JSON.parse(File.read("/var/lib/valpo/secrets/master.key"))
      result = {"active" => values.fetch("active")}
      if ARGV[0]
        result["previous_key_present"] = values.fetch("keys").key?(ARGV[0])
      end
      puts JSON.generate(result)
    RUBY
    command = [
      *REMOTE_RUBY.map { q(it) },
      "-rjson",
      "-e", q(ruby)
    ]
    command << q(previous_version.to_s) if previous_version
    JSON.parse(remote.capture(command.join(" ")))
  end

  def unset_custom_secret
    remote.run(
      "valpo service env unset web SMOKE_SECRET --project #{q(options.project)} --timeout 180"
    )
    remote.run(<<~SH)
      container="$(docker ps --filter #{q("label=valpo.service_id=#{service_ids.fetch("web")}")} --format '{{.Names}}' | head -n 1)"
      if docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' |
          grep -F 'SMOKE_SECRET=' >/dev/null; then
        echo 'Removed custom environment remains in container' >&2
        exit 1
      fi
    SH
  end

  def verify_domain_and_https
    puts "[smoke] verifying automatic domain"
    remote.run(
      "valpo domain list web --project #{q(options.project)} | grep -F #{q(domain)}"
    )
    puts "[smoke] verifying HTTPS"
    wait_for_https
  end

  def check_releases_and_logs
    puts "[smoke] checking releases and logs"
    remote.run("valpo release list web --project #{q(options.project)}")
    remote.run("valpo service logs web --project #{q(options.project)} --tail 50")
    remote.run("valpo project logs #{q(options.project)} --tail 50")
  end

  def reboot_and_verify
    puts "[smoke] rebooting #{options.ssh_target}"
    remote.run("systemctl reboot", allow_failure: true)
    wait_for_ssh(down: true, attempts: 30, delay: 2)
    wait_for_ssh(attempts: 90, delay: 5)
    wait_for_services

    puts "[smoke] verifying post-reboot services and app"
    remote.run("systemctl is-active #{SERVICES.map { q(it) }.join(" ")}")
    remote.run("curl -fsS http://127.0.0.1:7092/health")
    wait_for_https
    remote.run("valpo system repair --timeout 180")
    remote.run("valpo service list --project #{q(options.project)}")
    wait_for_https
  end

  def verify_bound_project_delete
    puts "[smoke] verifying project delete is blocked while services remain"
    deleted = remote.success?(
      "valpo project delete #{q(options.project)} --timeout 180 >/tmp/valpo-bound-delete.out 2>&1"
    )
    raise "Project delete succeeded while services were bound" if deleted
  end

  def delete_resources
    puts "[smoke] deleting services"
    %w[database cache web].each do
      remote.run(
        "valpo service delete #{q(it)} --project #{q(options.project)} " \
        "--force --timeout 180"
      )
    end
    puts "[smoke] deleting project"
    remote.run("valpo project delete #{q(options.project)} --timeout 180")
    @project_touched = false
  end

  def cleanup
    puts "[smoke] cleaning up #{options.project}"
    errors = []
    [
      -> { cleanup_resources if @project_touched },
      -> { verify_cleanup! if @project_id },
      -> { revoke_api_credential },
      -> { remove_manifest }
    ].each do
      it.call
    rescue => e
      errors << e
    end
    return if errors.empty?

    raise errors.map(&:message).join("; ")
  end

  def cleanup_resources
    wait_for_services
    %w[database cache web].each do
      next unless remote.success?(
        "valpo service show #{q(it)} --project #{q(options.project)} >/dev/null 2>&1"
      )

      remote.run(
        "valpo service delete #{q(it)} --project #{q(options.project)} " \
        "--force --timeout 180",
        allow_failure: true
      )
    end
    if remote.success?("valpo project show #{q(options.project)} >/dev/null 2>&1")
      remote.run(
        "valpo project delete #{q(options.project)} --timeout 180",
        allow_failure: true
      )
    end
    @project_touched = false
  end

  def revoke_api_credential
    return unless @api_credential_id

    result = remote.run(
      "valpo auth token revoke #{q(@api_credential_id)} >/dev/null",
      capture: true,
      allow_failure: true
    )
    raise "Temporary API credential could not be revoked" unless result.success?

    @api_credential_id = nil
    remote.api_token = nil
  end

  def remove_manifest
    result = remote.run(
      "rm -f #{q(@manifest_path)}",
      capture: true,
      allow_failure: true,
      auth: false
    )
    raise "Temporary project manifest could not be removed" unless result.success?
  end

  def verify_cleanup!
    puts "[smoke] verifying cleanup"
    if remote.success?("valpo project show #{q(options.project)} >/dev/null 2>&1")
      raise "Project still exists after delete"
    end

    labels = []
    labels << "valpo.project_id=#{@project_id}" if @project_id
    service_ids.each_value { labels << "valpo.service_id=#{it}" }
    labels.each do
      if remote.success?(
        "docker ps -a --filter #{q("label=#{it}")} --format '{{.Names}}' | grep ."
      )
        raise "Containers remain for #{it}"
      end
    end
    if remote.success?("grep -F #{q(domain)} /var/lib/valpo/caddy/valpo.caddy")
      raise "Route remains for #{domain}"
    end
  end

  def remote_json(command, auth: true)
    JSON.parse(remote.capture(command, auth:))
  rescue JSON::ParserError => e
    raise "Remote command returned invalid JSON: #{e.message}"
  end

  def container_environment_assertion(expected)
    <<~SH
      container="$(docker ps --filter #{q("label=valpo.service_id=#{service_ids.fetch("web")}")} --format '{{.Names}}' | head -n 1)"
      test -n "$container"
      docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' |
        grep -F #{q(expected)} >/dev/null
    SH
  end

  def wait_for_https(attempts: 60)
    attempts.times do
      result = runner.run(
        ["curl", "-fsSL", "https://#{domain}/"],
        capture: true,
        allow_failure: true
      )
      return if result.success? && result.stdout.match?(/nginx/i)

      sleep 2
    end
    raise "Timed out waiting for https://#{domain}/"
  end

  def wait_for_ssh(attempts:, delay:, down: false)
    attempts.times do
      available = remote.success?("true", connect_timeout: 5)
      return if down ? !available : available

      sleep delay
    end
    state = down ? "go down" : "become available"
    raise "Timed out waiting for SSH on #{options.ssh_target} to #{state}"
  end

  def wait_for_services(attempts: 90, delay: 5)
    attempts.times do
      return if remote.success?(
        "systemctl is-active #{SERVICES.map { q(it) }.join(" ")}",
        connect_timeout: 5
      )

      sleep delay
    end
    raise "Timed out waiting for Valpo services on #{options.ssh_target}"
  end

  def q(value)
    Shellwords.escape(value.to_s)
  end
end

if $PROGRAM_NAME == __FILE__
  VPSSmokeTest.new(VPSSmokeTest.parse(ARGV)).run
end
