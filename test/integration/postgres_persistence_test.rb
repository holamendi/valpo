# frozen_string_literal: true

require "test_helper"
require "open3"

class ValpoPostgresPersistenceTest < Minitest::Test
  VERSIONS = %w[16 17 18].freeze

  def test_named_volume_retains_data_after_container_recreation
    skip "set VALPO_POSTGRES_TEST=1 to run the PostgreSQL Docker integration" unless ENV["VALPO_POSTGRES_TEST"] == "1"

    network = "valpo-postgres-test-#{Process.pid}"
    docker!("network", "create", network)

    VERSIONS.each { verify_persistence(it, network:) }
  ensure
    docker("network", "rm", network) if network
  end

  private

  def verify_persistence(version, network:)
    name = "valpo-postgres-#{version}-#{Process.pid}"
    volume = "#{name}-data"
    image = "postgres:#{version}-alpine"
    target = Valpo::Services::Definitions::Postgres.new.volume_path(version)
    sentinel = "sentinel-#{version}"

    docker!("volume", "create", volume)
    run_postgres(name:, volume:, image:, target:, network:)
    wait_until_ready(name)
    docker!("exec", name, "psql", "-U", "valpo", "-d", "valpo", "-c",
      "CREATE TABLE valpo_persistence (value text NOT NULL); INSERT INTO valpo_persistence VALUES ('#{sentinel}');")

    docker!("rm", "--force", name)
    run_postgres(name:, volume:, image:, target:, network:)
    wait_until_ready(name)
    output = docker!("exec", name, "psql", "-U", "valpo", "-d", "valpo",
      "--tuples-only", "--no-align", "-c", "SELECT value FROM valpo_persistence;")

    assert_equal sentinel, output.strip, "PostgreSQL #{version} did not retain its sentinel"
  ensure
    docker("rm", "--force", name) if name
    docker("volume", "rm", "--force", volume) if volume
  end

  def run_postgres(name:, volume:, image:, target:, network:)
    docker!(
      "run", "--detach", "--name", name, "--network", network,
      "--env", "POSTGRES_DB=valpo", "--env", "POSTGRES_USER=valpo",
      "--env", "POSTGRES_PASSWORD=integration-test-only",
      "--volume", "#{volume}:#{target}", image
    )
  end

  def wait_until_ready(name)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
    ready_since = nil

    loop do
      _, _, status = docker("exec", name, "pg_isready", "-U", "valpo", "-d", "valpo")
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if status.success?
        ready_since ||= now
        return if now - ready_since >= 1
      else
        ready_since = nil
      end
      break if now >= deadline

      sleep 0.25
    end

    logs, = docker("logs", name)
    flunk "PostgreSQL did not become ready:\n#{logs}"
  end

  def docker(*arguments)
    Open3.capture3("docker", *arguments)
  end

  def docker!(*arguments)
    stdout, stderr, status = docker(*arguments)
    return stdout if status.success?

    flunk "docker #{arguments.join(" ")} failed:\n#{stdout}\n#{stderr}"
  end
end
