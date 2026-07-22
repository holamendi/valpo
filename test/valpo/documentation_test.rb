# frozen_string_literal: true

require "test_helper"

class ValpoDocumentationTest < Minitest::Test
  def test_relative_documentation_links_resolve
    markdown_files.each do
      markdown_path = it
      File.read(markdown_path).scan(/\[[^\]]+\]\(([^)]+)\)/).flatten.each do
        next if it.match?(%r{\A(?:https?://|mailto:|#)})

        relative = it.delete_prefix("<").delete_suffix(">").split("#", 2).first
        resolved = File.expand_path(relative, File.dirname(markdown_path))
        assert File.exist?(resolved), "Broken link in #{relative_path(markdown_path)}: #{it}"
      end
    end
  end

  private

  def markdown_files
    [File.join(Valpo.root, "README.md"), *Dir[File.join(Valpo.root, "docs", "*.md")]].sort
  end

  def relative_path(path)
    path.delete_prefix("#{Valpo.root}/")
  end
end
