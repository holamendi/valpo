# frozen_string_literal: true

require "test_helper"
require "valpo/cli"

class ValpoCLITest < Minitest::Test
  def test_cli_exits_nonzero_on_failures
    assert_equal true, Valpo::CLI.exit_on_failure?
  end
end
