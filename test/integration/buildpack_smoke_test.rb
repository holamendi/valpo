# frozen_string_literal: true

require "open3"
require "test_helper"

class ValpoBuildpackSmokeTest < Minitest::Test
  include ValpoTestDatabase

  def test_build_inspect_and_run
    skip "set VALPO_TEST_BUILDPACKS=1 to run the real buildpack smoke test" unless ENV["VALPO_TEST_BUILDPACKS"] == "1"
    skip "buildpack integration requires Linux" unless RUBY_PLATFORM.include?("linux")
    skip "pack and Docker are required" unless command?("pack") && command?("docker")

    project = create_project
    service = create_app_service(project:)
    source = Valpo::Source.create(
      project_id: project.id,
      name: "node",
      provider: "github",
      repository: "acme/node"
    )
    target = Valpo::BuildTarget.create(
      project_id: project.id,
      source_id: source.id,
      name: "node",
      strategy: "buildpack"
    )
    image = "valpo/buildpack-smoke:#{Process.pid}"
    docker = Valpo::Docker::Client.new
    cache_manager = Valpo::Builds::CacheManager.new(docker:)
    checkout = Valpo::Sources::Preflight::Result.new(
      checkout: fixture_path,
      strategy: "buildpack",
      dockerfile: nil,
      context: fixture_path,
      commit: "a" * 40,
      ref: "HEAD"
    )
    builder = Valpo::Builds::BuildpackBuilder.new(
      client: Valpo::Builds::BuildpackClient.new,
      runner: Valpo::Builds::CommandRunner.new,
      cache_manager:,
      builder: Valpo::Config::DEFAULT_BUILDPACK_BUILDER,
      timeout: 1_800
    )

    result = builder.build(
      checkout:,
      build_target: target,
      image:,
      service:,
      queue: FakeQueue.new,
      job_id: "job_buildpack_smoke"
    )
    stdout, stderr, status = Open3.capture3(
      "docker", "run", "--rm",
      "--entrypoint", "/cnb/lifecycle/launcher",
      image,
      "node", "-e", "process.stdout.write('buildpack-smoke-ok')"
    )

    assert status.success?, stderr
    assert_equal "buildpack-smoke-ok", stdout
    assert result.metadata.fetch("buildpacks").any?
    assert result.metadata.fetch("processes").any? { it.fetch("type") == "web" }
  ensure
    cleanup_image(image) if defined?(image) && image
    if defined?(cache_manager) && cache_manager && defined?(target) && target
      begin
        cache_manager.remove(
          build_target_id: target.id,
          queue: FakeQueue.new,
          job_id: "job_buildpack_smoke"
        )
      rescue Valpo::Error
        nil
      end
    end
  end

  private

  def fixture_path
    File.expand_path("../fixtures/buildpack-node", __dir__)
  end

  def command?(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do
      File.executable?(File.join(it, name))
    end
  end

  def cleanup_image(image)
    system("docker", "image", "rm", "--force", image, out: File::NULL, err: File::NULL)
  end

  class FakeQueue
    def event(*)
    end
  end
end
