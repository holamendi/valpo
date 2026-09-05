# frozen_string_literal: true

require "fileutils"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "valpo"

VALPO_TEST_DIR = Dir.mktmpdir("valpo-test")
ENV["VALPO_CLI_CONFIG"] = File.join(VALPO_TEST_DIR, "cli", "cli.json")
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

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { require it }

Minitest.after_run do
  Valpo::Database.disconnect
  FileUtils.remove_entry(VALPO_TEST_DIR) if Dir.exist?(VALPO_TEST_DIR)
end

module ValpoTestDatabase
  TABLE_DELETE_ORDER = %i[
    job_events jobs api_credentials github_webhook_deliveries github_app_setups provider_credentials
    service_environment_variables service_dependencies domains releases app_service_configs managed_service_configs
    services build_targets sources projects platform_domains
  ].freeze

  def setup
    super
    clean_database
  end

  def db
    Valpo::Database.connection
  end

  def create_project(name: "hello")
    Valpo::Project.create(name:)
  end

  def create_platform_domain(hostname: "apps.example.com", status: "verified", active: true)
    Valpo::PlatformDomain.create(
      hostname:,
      status:,
      active:,
      verified_at: (Time.now.utc if status == "verified")
    )
  end

  def create_domain(service:, hostname: "hello.example.com", status: "verified", kind: "custom", **attributes)
    Valpo::Domain.create({
      service_id: service.id,
      hostname:,
      status:,
      kind:,
      verified_at: (Time.now.utc if status == "verified")
    }.merge(attributes))
  end

  def create_app_service(project: nil, name: "web", kind: "web", status: "created", port: 3000, command: [])
    project ||= create_project
    service = Valpo::Services::Creator.call(
      project_id: project.id,
      name:,
      type: kind,
      internal_port: (port if kind == "web"),
      command:
    )
    service.update(status:)
    service
  end

  def create_managed_service(project: nil, name: "database", kind: "postgres", version: nil, status: "running", runtime: true)
    project ||= create_project
    service = Valpo::Services::Creator.call(project_id: project.id, name:, type: kind, version:)
    Valpo::Services::Registry.managed_config(service).update(Valpo::Services::Registry.runtime_attributes(service)) if runtime
    service.update(status:)
    service
  end

  def create_release(service:, image: "example/app:v1", status: "pending", **attributes)
    Valpo::Release.create({
      service_id: service.id,
      source_type: "registry",
      source_ref: image,
      artifact_ref: image,
      status:,
      internal_port: Valpo::AppServiceConfig[service.id]&.internal_port
    }.merge(attributes))
  end

  private

  def clean_database
    db.transaction do
      TABLE_DELETE_ORDER.each { db[it].delete }
      if db.table_exists?(:control_plane_states)
        db[:control_plane_states].where(id: Valpo::ControlPlaneState::SINGLETON_ID).update(
          api_bootstrapped_at: nil,
          updated_at: Time.now.utc
        )
      end
    end
  end
end
