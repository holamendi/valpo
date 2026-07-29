# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../packaging/vps_smoke_test"

class VPSSmokeTestTest < Minitest::Test
  class FakeRunner
    Result = Data.define(:stdout)

    attr_reader :calls

    def initialize
      @calls = []
    end

    def run(argv, **options)
      calls << {argv:, options:}
      Result.new(stdout: "")
    end
  end

  def test_remote_api_token_is_sent_through_standard_input
    runner = FakeRunner.new
    remote = VPSSmokeTest::Remote.new("root@example.test", runner:)
    remote.api_token = "valpo_secret"

    remote.run("valpo system status")

    call = runner.calls.fetch(0)
    assert_equal ["ssh", "root@example.test", "bash -s"], call.fetch(:argv)
    refute_includes call.fetch(:argv).join(" "), "valpo_secret"
    assert_includes call.dig(:options, :input), "export VALPO_API_TOKEN=valpo_secret"
    assert_includes call.dig(:options, :input), "valpo system status"
  end

  def test_parser_preserves_the_shell_wrapper_interface
    options = VPSSmokeTest.parse(
      ["root@example.test", "apps.example.test", "--skip-deps", "--project", "smoke"]
    )

    assert_equal "root@example.test", options.ssh_target
    assert_equal "apps.example.test", options.domain_suffix
    assert_equal :skip_deps, options.install_mode
    assert_equal "smoke", options.project
  end
end
