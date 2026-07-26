# frozen_string_literal: true

require "test_helper"

class ValpoBuildsCacheManagerTest < Minitest::Test
  def test_uses_stable_target_scoped_cache_names
    manager = Valpo::Builds::CacheManager.new(docker: FakeDocker.new)

    assert_equal "valpo-cnb-build-target_123", manager.build_cache("target_123")
    assert_equal "valpo-cnb-launch-target_123", manager.launch_cache("target_123")
  end

  def test_removes_only_the_target_build_and_launch_caches
    docker = FakeDocker.new
    manager = Valpo::Builds::CacheManager.new(docker:)

    manager.remove(build_target_id: "target_123", queue: FakeQueue.new, job_id: "job_test")

    assert_equal(
      [
        [:volume_rm, "valpo-cnb-build-target_123", true],
        [:volume_rm, "valpo-cnb-launch-target_123", true]
      ],
      docker.commands
    )
  end

  def test_prepares_owned_build_and_launch_cache_volumes
    docker = FakeDocker.new
    manager = Valpo::Builds::CacheManager.new(docker:)

    manager.prepare(build_target_id: "target_123", queue: FakeQueue.new, job_id: "job_test")

    assert_equal(
      [
        [:volume_create, "valpo-cnb-build-target_123", {"valpo.owned" => "true"}],
        [:volume_create, "valpo-cnb-launch-target_123", {"valpo.owned" => "true"}]
      ],
      docker.commands
    )
  end

  class FakeDocker
    attr_reader :commands

    def initialize
      @commands = []
    end

    def volume_rm_command(name, force:)
      [:volume_rm, name, force]
    end

    def volume_create_command(name, labels:)
      [:volume_create, name, labels]
    end

    def execute(command)
      commands << command
      {stdout: "", stderr: "", status: 0, success: true}
    end
  end

  class FakeQueue
    def event(*)
    end
  end
end
