# frozen_string_literal: true

# Invoked with the candidate's Ruby and bundle, as the valpo user, while the
# public API and worker are stopped. Never execute queued work in this probe.
require "bundler/setup"
require "json"
require "net/http"
require "rackup"
require "sqlite3"
require "valpo"

config = Valpo::Config.load
Valpo::ReleaseMetadata.current
mode = ARGV.fetch(0)
if %w[inspect backup].include?(mode)
  raise "Existing database and keyring are required" unless File.file?(config.database_path) && File.file?(config.encryption_key_path)
  source = SQLite3::Database.new(config.database_path, readonly: true)
  begin
    if mode == "inspect"
      puts JSON.generate(database: config.database_path, keyring: config.encryption_key_path,
        schema: source.get_first_value("SELECT version FROM schema_info"),
        busy: source.get_first_value("SELECT COUNT(*) FROM jobs WHERE status IN ('queued','running')").positive?)
    else
      destination = SQLite3::Database.new(ARGV.fetch(1))
      backup = SQLite3::Backup.new(destination, "main", source, "main")
      begin
        result = backup.step(-1)
        raise "SQLite backup did not complete" unless result == SQLite3::Constants::ErrorCode::DONE
      ensure
        backup.finish
      end
      raise "SQLite checkpoint failed integrity check" unless destination.get_first_value("PRAGMA integrity_check") == "ok"
      puts JSON.generate(ok: true)
    end
  ensure
    destination&.close
    source.close
  end
  exit
end

Valpo::Boot.run(config:)
Valpo::Jobs::HandlerRegistry.build(config:)
credential, token = Valpo::APICredential.issue(name: "Upgrade readiness probe", scopes: ["read"])
pid = nil
begin
  # The parent is launched in a private network namespace. Even a candidate
  # configured to listen on all interfaces cannot receive external requests.
  pid = Process.spawn(File.join(Valpo.root, "bin/valpo-api"), "--config", ENV.fetch("VALPO_CONFIG"), out: $stderr, err: $stderr)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
  loop do
    raise "Candidate API exited before readiness" if Process.waitpid(pid, Process::WNOHANG)
    begin
      http = Net::HTTP.new("127.0.0.1", config.api_port, nil)
      http.open_timeout = 1
      http.read_timeout = 1
      response = http.get("/health", "Authorization" => "Bearer #{token}")
      health = JSON.parse(response.body)
      raise "Candidate health response is invalid" unless response.code == "200" && health["ok"] && health["version"] == Valpo::VERSION
      puts JSON.generate(health)
      break
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Net::OpenTimeout, Net::ReadTimeout
      raise "Candidate API readiness timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.2
    end
  end
ensure
  if pid
    begin
      Process.kill("TERM", pid)
      Process.waitpid(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
  credential.destroy
  Valpo::Database.disconnect
end
