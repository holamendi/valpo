# frozen_string_literal: true

# Run only on a disposable installed host. Uses a local source fixture in place
# of GitHub authentication; all provisioning, builds, and runtime calls are real.
require "bundler/setup"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "valpo"

$stdout.sync = true
Valpo::Boot.run
raise "Set VALPO_ACCEPTANCE=1 on a disposable host" unless ENV["VALPO_ACCEPTANCE"] == "1"

class AcceptanceSource
  def checkout(source:, destination:, ref:)
    fixture = File.expand_path("fixtures/buildpack-ruby", __dir__)
    raise "Acceptance fixture is missing" unless File.file?(File.join(fixture, "Procfile"))

    FileUtils.cp_r(Dir[File.join(fixture, "{*,.*}")].reject { %w[. ..].include?(File.basename(it)) }, destination)
    "a" * 40
  end
end

class AcceptanceQueue
  def event(_id, stream, message)
    # Inspect results can include image environment values. This test keeps
    # operational logs on the disposable host, never in release artifacts.
    puts "[#{stream}] #{message}"
  end
end

name = "buildpack-acceptance"
queue = AcceptanceQueue.new
job_id = "acceptance"
if ARGV == ["verify"]
  service = Valpo::Service.where(project_id: Valpo::Project.where(name:).first.id, name: "web").first
  release = Valpo::Release.where(service_id: service.id).order(Sequel.desc(:created_at)).first
else
  manifest = Valpo::Manifests::ProjectManifest.parse(<<~TOML)
    schema = 1
    [project]
    name = "#{name}"
    [sources.app]
    provider = "github"
    repository = "valpo/acceptance-fixture"
    ref = "main"
    [builds.app]
    source = "app"
    strategy = "buildpack"
    buildpacks = ["heroku/ruby", "heroku/procfile"]
    [services.web]
    type = "web"
    build = "app"
    port = 3000
    healthcheck = "/health"
    depends_on = ["database"]
    [services.database]
    type = "postgres"
    version = "18"
  TOML
  preflight = Valpo::Sources::Preflight.new(fetcher: AcceptanceSource.new)
  project = Valpo::Manifests::Reconciler.new(preflight:).apply(manifest, queue:, job_id:)
  raise "Manifest did not converge" unless Valpo::Manifests::Planner.call(manifest).fetch("actions").all? { it.fetch("operation") == "noop" }

  service = Valpo::Service.where(project_id: project.id, name: "web").first
  target = Valpo::AppServiceConfig[service.id].build_target
  raise "Buildpack order not persisted" unless target.buildpacks == %w[heroku/ruby heroku/procfile]

  docker = Valpo::Docker::Client.new
  builds = Valpo::Builds::Orchestrator.new(
    source_fetcher: AcceptanceSource.new,
    deployment_lifecycle: Valpo::Deployments::Lifecycle.new,
    target_lock: Valpo::Builds::TargetLock.new(database_path: Valpo.config.database_path),
    builders: {"buildpack" => Valpo::Builds::BuildpackBuilder.new(
      client: Valpo::Builds::BuildpackClient.new,
      runner: Valpo::Builds::CommandRunner.new,
      cache_manager: Valpo::Builds::CacheManager.new(docker:),
      builder: Valpo.config.buildpack_builder,
      timeout: 1800
    )}
  )
  builds.deploy_source(service_id: service.id, ref: nil, internal_port: nil, healthcheck_path: nil, queue:, job_id:)
  release = Valpo::Release.where(service_id: service.id).order(Sequel.desc(:created_at)).first
  raise "Build did not produce a ready release" unless %w[active ready].include?(release.status)
  raise "Builder was not pinned" unless release.build_metadata.fetch("builder").include?("@sha256:")
  response = Net::HTTP.post(URI("http://#{release.route_target}/items/persist-after-reboot"), "")
  raise "Database write failed: #{response.code}" unless response.code == "201"
  managed = Valpo::ManagedServiceConfig[Valpo::Service.where(project_id: project.id, name: "database").first.id]
  raise "Restart failed" unless system("docker", "restart", managed.container_name, release.container_name)
end

30.times do
  response = Net::HTTP.get_response(URI("http://#{release.route_target}/items"))
  if response.code == "200" && JSON.parse(response.body).include?("persist-after-reboot")
    puts "PASS: Ruby buildpacks, manifest, Postgres binding, and persisted HTTP read after restart"
    exit 0
  end
  sleep 1
rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Net::ReadTimeout, EOFError
  sleep 1
end
raise "Persisted item was not readable"
