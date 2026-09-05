# frozen_string_literal: true

require "test_helper"

class ValpoBuildsBuildpackEnvironmentTest < Minitest::Test
  def test_repairs_incomplete_containerd_content_and_verifies_export
    runner = FakeRunner.new(export_error: "no suitable export target found")
    result = prepare(runner)
    assert_equal "test/builder@sha256:resolved", result.fetch("builder")
    assert_equal "test/run@sha256:resolved", result.fetch("run_image")
    assert_equal 2, runner.commands.count { it.first == "sh" }
    assert runner.commands.any? { it[1..2] == %w[buildx build] }
    assert runner.commands.any? { it[1..2] == %w[image rm] }
    assert_equal "FROM test/run@sha256:resolved\n", runner.dockerfile
  end

  def test_does_not_materialize_healthy_images
    runner = FakeRunner.new
    prepare(runner)
    refute runner.commands.any? { it[1..2] == %w[buildx build] }
  end

  def test_does_not_retry_unrelated_export_failures
    runner = FakeRunner.new(export_error: "permission denied")
    error = assert_raises(Valpo::ValidationError) { prepare(runner) }
    assert_match "permission denied", error.message
    refute runner.commands.any? { it[1..2] == %w[buildx build] }
  end

  def test_rejects_invalid_builder_run_image_before_using_it_in_a_dockerfile
    runner = FakeRunner.new(run_image: "test/run\nRUN evil")
    assert_raises(Valpo::ValidationError) { prepare(runner) }
    refute runner.commands.any? { it[1..2] == %w[buildx build] }
  end

  def test_fails_before_pulling_when_buildx_is_missing
    runner = FakeRunner.new(missing_buildx: true)
    error = assert_raises(Valpo::ValidationError) { prepare(runner) }
    assert_match "buildx", error.message
    refute runner.commands.any? { it[1] == "pull" }
  end

  private

  def prepare(runner)
    Valpo::Builds::BuildpackEnvironment.new(runner:).prepare(builder: "test/builder", timeout: 30, queue: Valpo::Builds::BuildpackEnvironment::QuietQueue.new, job_id: "test")
  end

  class FakeRunner
    attr_reader :commands, :dockerfile

    def initialize(export_error: nil, run_image: "test/run", missing_buildx: false)
      @export_error, @run_image, @missing_buildx = export_error, run_image, missing_buildx
      @commands = []
    end

    def run(command, **)
      commands << command
      stdout = ""
      if command[1..2] == %w[buildx version] && @missing_buildx
        return failure("buildx missing")
      elsif command[1] == "version" && command.first == "docker"
        stdout = "linux/amd64"
      elsif command[1] == "info"
        stdout = '[["driver-type","io.containerd.snapshotter.v1"]]'
      elsif command.include?("{{json .RepoDigests}}")
        stdout = JSON.generate(["#{command.last}@sha256:resolved"])
      elsif command.any? { it.include?("io.buildpacks.builder.metadata") }
        stdout = JSON.generate("stack" => {"runImage" => {"image" => @run_image}})
      elsif command.first == "sh" && @export_error
        error, @export_error = @export_error, nil
        return failure(error)
      elsif command[1..2] == %w[buildx build]
        @dockerfile = File.read(File.join(command.last, "Dockerfile"))
      end
      {stdout:, stderr: "", success: true, status: 0}
    end

    def failure(stderr)
      {stdout: "", stderr:, success: false, status: 1}
    end
  end
end
