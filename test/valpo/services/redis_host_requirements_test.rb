# frozen_string_literal: true

require "test_helper"

class ValpoServicesRedisHostRequirementsTest < Minitest::Test
  def test_accepts_the_redis_overcommit_setting
    requirements = requirements_with("1\n")

    assert requirements.validate!
  end

  def test_rejects_an_incompatible_overcommit_setting
    requirements = requirements_with("0\n")

    error = assert_raises(Valpo::ValidationError) { requirements.validate! }

    assert_includes error.message, "vm.overcommit_memory=1"
    assert_includes error.message, 'current value: "0"'
  end

  def test_reports_an_unreadable_kernel_setting
    requirements = Valpo::Services::RedisHostRequirements.new(
      reader: ->(_path) { raise Errno::ENOENT, "missing" }
    )

    error = assert_raises(Valpo::ValidationError) { requirements.validate! }

    assert_includes error.message, "cannot verify"
  end

  private

  def requirements_with(value)
    Valpo::Services::RedisHostRequirements.new(
      reader: lambda do
        assert_equal "/proc/sys/vm/overcommit_memory", it
        value
      end
    )
  end
end
