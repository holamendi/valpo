# frozen_string_literal: true

require "json"
require "test_helper"

class ValpoStorageMaintenanceTest < Minitest::Test
  include ValpoTestDatabase

  NOW = Time.utc(2026, 7, 27, 12)
  OLD = NOW - (10 * 86_400)

  def test_image_cleanup_retains_current_and_rollback_images
    service, target = source_service
    oldest = git_release(service:, target:, commit: "1" * 40, image_id: image_id("1"), status: "inactive", version: 1)
    rollback = git_release(service:, target:, commit: "2" * 40, image_id: image_id("2"), status: "inactive", version: 2)
    active = git_release(service:, target:, commit: "3" * 40, image_id: image_id("3"), status: "active", version: 3)
    docker = FakeDocker.new(images: [
      image("valpo/hello/web:#{oldest.source_ref[0, 12]}", oldest.image_digest),
      image("valpo/hello/web:#{rollback.source_ref[0, 12]}", rollback.image_digest),
      image("valpo/hello/web:#{active.source_ref[0, 12]}", active.image_digest)
    ])

    result = image_cleaner(docker:, retention_count: 2).call(
      dry_run: false,
      queue:,
      job_id: maintenance_job.id
    )

    assert_equal 1, result.fetch(:image_references)
    assert_equal false, oldest.refresh.artifact_available
    assert_equal true, rollback.refresh.artifact_available
    assert_equal true, active.refresh.artifact_available
    assert_includes docker.commands, [:image_rm, "valpo/hello/web:#{oldest.source_ref[0, 12]}"]
    assert_includes docker.commands, [:image_rm, oldest.image_digest]
    refute_includes docker.commands, [:image_rm, rollback.image_digest]
  end

  def test_image_cleanup_does_not_guess_ownership_from_a_valpo_tag
    docker = FakeDocker.new(images: [
      image("valpo/deleted/web:abc123", image_id("a")),
      image("unrelated/app:latest", image_id("b"))
    ])
    result = image_cleaner(docker:, retention_count: 3).call(
      dry_run: true,
      queue:,
      job_id: maintenance_job.id
    )

    assert_equal 0, result.fetch(:image_references)
    refute docker.commands.any? { it.first == :image_rm }
  end

  def test_service_image_cleanup_uses_release_ownership_before_records_are_deleted
    service, target = source_service
    release = git_release(
      service:,
      target:,
      commit: "4" * 40,
      image_id: image_id("4"),
      status: "active",
      version: 1
    )
    docker = FakeDocker.new

    result = image_cleaner(docker:, retention_count: 3).remove_for_service(
      service_id: service.id,
      queue:,
      job_id: maintenance_job.id
    )

    assert_equal 1, result.fetch(:image_references)
    assert_equal false, release.refresh.artifact_available
    assert_includes docker.commands, [:image_rm, "valpo/hello/web:#{release.source_ref[0, 12]}"]
  end

  def test_build_cache_cleanup_only_removes_stale_valpo_cache_volumes
    _service, target = source_service(created_at: OLD)
    names = ["valpo-cnb-build-#{target.id}", "valpo-cnb-launch-#{target.id}"]
    docker = FakeDocker.new(volumes: names + ["valpo-data"])
    cleaner = Valpo::Storage::BuildCacheCleaner.new(
      docker:,
      cache_manager: Valpo::Builds::CacheManager.new(docker:),
      retention: 86_400,
      clock: -> { NOW }
    )

    result = cleaner.call(dry_run: false, queue:, job_id: maintenance_job.id)

    assert_equal 2, result.fetch(:build_cache_volumes)
    assert_includes docker.commands, [:volume_rm, names.first, true]
    assert_includes docker.commands, [:volume_rm, names.last, true]
    refute docker.commands.any? { it.include?("valpo-data") }
  end

  def test_cache_retention_uses_typed_latest_release_timestamp
    service, target = source_service(created_at: OLD)
    release = git_release(service:, target:, commit: "5" * 40, image_id: image_id("5"), status: "inactive", version: 1)
    names = ["valpo-cnb-build-#{target.id}", "valpo-cnb-launch-#{target.id}"]
    docker = FakeDocker.new(volumes: names)
    cleaner = Valpo::Storage::BuildCacheCleaner.new(docker:, cache_manager: Valpo::Builds::CacheManager.new(docker:), retention: 86_400, clock: -> { NOW })
    release.update(created_at: NOW)
    assert_equal 0, cleaner.call(dry_run: false, queue:, job_id: maintenance_job.id).fetch(:build_cache_volumes)
    release.update(created_at: OLD)
    assert_equal 2, cleaner.call(dry_run: false, queue:, job_id: maintenance_job.id).fetch(:build_cache_volumes)
  end

  def test_container_cleanup_removes_only_unreferenced_owned_containers
    service = create_app_service
    create_release(service:, status: "active", container_name: "valpo-active", route_target: "127.0.0.1:20000")
    docker = FakeDocker.new(containers: [
      container("valpo-active"),
      container("valpo-orphan")
    ])
    cleaner = Valpo::Storage::ContainerCleaner.new(
      docker:,
      grace_period: 86_400,
      clock: -> { NOW }
    )

    result = cleaner.call(dry_run: false, queue:, job_id: maintenance_job.id)

    assert_equal 1, result.fetch(:orphaned_containers)
    assert_includes docker.commands, [:container_rm, "valpo-orphan", true]
    refute_includes docker.commands, [:container_rm, "valpo-active", true]
  end

  def test_history_cleanup_bounds_completed_jobs_and_webhook_deliveries
    old_job = completed_job(finished_at: OLD)
    recent_job = completed_job(finished_at: NOW)
    Valpo::GitHubWebhookDelivery.create(
      id: "old-delivery",
      event: "push",
      payload_digest: "a" * 64,
      created_at: OLD
    )
    cleaner = Valpo::Storage::HistoryCleaner.new(retention: 86_400, clock: -> { NOW })

    result = cleaner.call(dry_run: false, queue:, job_id: maintenance_job.id)

    assert_equal 1, result.fetch(:jobs)
    assert_operator result.fetch(:job_events), :>=, 1
    assert_equal 1, result.fetch(:github_webhook_deliveries)
    assert_nil Valpo::Job[old_job.id]
    assert Valpo::Job[recent_job.id]
    assert_nil Valpo::GitHubWebhookDelivery["old-delivery"]
  end

  private

  def queue
    @queue ||= Valpo::Jobs::Queue.new
  end

  def maintenance_job
    @maintenance_job ||= queue.enqueue("maintain_storage")
  end

  def source_service(created_at: OLD)
    project = create_project
    service = create_app_service(project:)
    source = Valpo::Source.create(
      project_id: project.id,
      owner_service_id: service.id,
      name: "web",
      provider: "github",
      repository: "acme/web",
      ref: "main"
    )
    target = Valpo::BuildTarget.create(
      project_id: project.id,
      source_id: source.id,
      owner_service_id: service.id,
      name: "web",
      strategy: "dockerfile",
      dockerfile: "Dockerfile",
      context: ".",
      created_at:,
      updated_at: created_at
    )
    Valpo::AppServiceConfig[service.id].update(build_target_id: target.id)
    [service, target]
  end

  def git_release(service:, target:, commit:, image_id:, status:, version:)
    Valpo::Release.create(
      service_id: service.id,
      build_target_id: target.id,
      version:,
      source_type: "git",
      source_ref: commit,
      artifact_ref: image_id,
      image_digest: image_id,
      build_strategy: "dockerfile",
      status:,
      created_at: OLD
    )
  end

  def image_id(character)
    "sha256:#{character * 64}"
  end

  def image(reference, id)
    repository, tag = reference.split(":", 2)
    {
      "Repository" => repository,
      "Tag" => tag,
      "ID" => id,
      "CreatedAt" => OLD.iso8601
    }
  end

  def container(name)
    {"Names" => name, "CreatedAt" => OLD.iso8601}
  end

  def image_cleaner(docker:, retention_count:)
    Valpo::Storage::ImageCleaner.new(
      docker:,
      retention_count:,
      grace_period: 86_400,
      clock: -> { NOW }
    )
  end

  def completed_job(finished_at:)
    job = queue.enqueue("system_check")
    job.update(status: "succeeded", finished_at:)
    job
  end

  class FakeDocker
    attr_reader :commands

    def initialize(images: [], containers: [], volumes: [])
      @images = images
      @containers = containers
      @volumes = volumes
      @commands = []
    end

    def image_list_command
      [:image_list]
    end

    def image_rm_command(reference)
      [:image_rm, reference]
    end

    def container_list_command(**)
      [:container_list]
    end

    def rm_command(name, force:)
      [:container_rm, name, force]
    end

    def volume_list_command(**)
      [:volume_list]
    end

    def volume_rm_command(name, force:)
      [:volume_rm, name, force]
    end

    def execute(command)
      commands << command
      case command.first
      when :image_list
        success(@images.map { JSON.generate(it) }.join("\n"))
      when :container_list
        success(@containers.map { JSON.generate(it) }.join("\n"))
      when :volume_list
        success(@volumes.join("\n"))
      else
        success("")
      end
    end

    private

    def success(stdout)
      {stdout:, stderr: "", status: 0, success: true}
    end
  end
end
