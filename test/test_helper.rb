# frozen_string_literal: true

require "fileutils"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "valpo"

VALPO_TEST_DIR = Dir.mktmpdir("valpo-test")
VALPO_TEST_CONFIG = Valpo::Config.new(
  env: "test",
  root: Valpo.root,
  database_path: File.join(VALPO_TEST_DIR, "valpo-test.sqlite3"),
  api_host: "127.0.0.1",
  api_port: 7092,
  caddy_config_path: File.join(VALPO_TEST_DIR, "Caddyfile"),
  caddy_reload_config_path: File.join(VALPO_TEST_DIR, "Caddyfile"),
  docker_network: "valpo",
  worker_poll_interval: 0.01,
  app_port_start: 20_000,
  app_port_end: 20_099,
  healthcheck_timeout: 1,
  deploy_drain_delay: 0
)

Valpo::Boot.run(config: VALPO_TEST_CONFIG, migrate: true)

require "valpo/jobs/worker"
require "valpo/docker/client"
require "valpo/caddy/renderer"
require "valpo/caddy/client"

Minitest.after_run do
  Valpo::Database.disconnect
  FileUtils.remove_entry(VALPO_TEST_DIR) if Dir.exist?(VALPO_TEST_DIR)
end

module ValpoTestDatabase
  TABLE_DELETE_ORDER = %i[job_events jobs domains releases projects].freeze

  def setup
    super
    clean_database
  end

  def db
    Valpo::Database.connection
  end

  private

  def clean_database
    db.transaction do
      TABLE_DELETE_ORDER.each { |table| db[table].delete }
    end
  end
end
