# frozen_string_literal: true

require "test_helper"
require "stringio"

class ValpoCLIDocsTest < Minitest::Test
  def test_cli_guide_is_fresh
    assert_equal Valpo::CLI::Docs.render, File.read(Valpo::CLI::Docs::PATH), "Run `rake cli:docs` to refresh docs/valpo-cli.md"
  end

  def test_documented_commands_match_registry
    documented = Valpo::CLI::Registry::COMMANDS.map(&:first)
    assert_equal documented.uniq, documented
    refute_includes Valpo::CLI::Registry::GROUPS.except("job").keys, "job"
  end

  def test_every_command_definition_is_registered_and_has_help
    Valpo::CLI::Registry::COMMANDS.each do |path, _command, _hidden|
      out = StringIO.new
      err = StringIO.new
      status = Valpo::CLI.call(path.split + ["--help"], out:, err:)

      assert_equal 0, status, path
      refute_empty out.string, path
      assert_empty err.string, path
    end
  end
end
