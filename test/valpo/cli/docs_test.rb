# frozen_string_literal: true

require "test_helper"

class ValpoCLIDocsTest < Minitest::Test
  def test_cli_guide_is_fresh
    assert_equal Valpo::CLI::Docs.render, File.read(Valpo::CLI::Docs::PATH), "Run `rake cli:docs` to refresh docs/valpo-cli.md"
  end

  def test_documented_commands_match_registry
    documented = Valpo::CLI::Registry::COMMANDS.map(&:first)
    assert_equal documented.uniq, documented
    refute_includes Valpo::CLI::Registry::GROUPS.except("job").keys, "job"
  end
end
