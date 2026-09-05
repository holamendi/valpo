# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"
require "digest"

class ValpoPackagingReleasePublicationTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    @assets = File.join(@root, "assets")
    FileUtils.mkdir_p(@assets)
    @log = File.join(@root, "calls")
    File.write(File.join(@root, "gh"), <<~SH)
      #!/bin/bash
      echo "$*" >> "$CALL_LOG"
      [[ "$1 $2" != "$FAIL_COMMAND" ]] || exit 1
      if [[ "$1" == api ]]; then echo true; fi
    SH
    File.chmod(0o755, File.join(@root, "gh"))
    %w[amd64 arm64].each do |arch|
      %w[tar.zst spdx.json provenance.intoto.jsonl sbom.intoto.jsonl].each do
        File.write(File.join(@assets, "valpo-0.1.2-rc.1-linux-#{arch}.#{it}"), "test")
      end
    end
    sums = Dir[File.join(@assets, "*")].map { "#{Digest::SHA256.file(it).hexdigest}  ./#{File.basename(it)}\n" }.join
    File.write(File.join(@assets, "SHA256SUMS"), sums)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def publish(failure: "")
    Open3.capture3({"PATH" => "#{@root}:#{ENV.fetch("PATH")}", "CALL_LOG" => @log, "FAIL_COMMAND" => failure},
      "bash", File.expand_path("../../packaging/release/publish.sh", __dir__), "v0.1.2-rc.1", @assets)
  end

  def test_publication_uploads_complete_assets_before_publishing_draft
    stdout, stderr, status = publish
    assert status.success?, "#{stdout}\n#{stderr}"
    calls = File.readlines(@log)
    assert_match(/release create.*--draft.*--prerelease/, calls[0])
    assert_match(/release upload.*SHA256SUMS.*amd64.*arm64/, calls[1])
    assert_match(/release edit.*--draft=false/, calls[2])
    assert_match(/api.*immutable/, calls[3])
    refute_includes calls.join, "--clobber"
  end

  def test_existing_release_and_failed_upload_never_publish
    ["release create", "release upload"].each do
      FileUtils.rm_f(@log)
      _stdout, _stderr, status = publish(failure: it)
      refute status.success?
      refute_includes File.read(@log), "release edit"
    end
  end

  def test_missing_or_corrupt_assets_fail_before_creating_release
    asset = Dir[File.join(@assets, "*.tar.zst")].first
    File.write(asset, "corrupt")
    _stdout, _stderr, status = publish
    refute status.success?
    refute_path_exists @log
    File.unlink(asset)
    _stdout, _stderr, status = publish
    refute status.success?
    refute_path_exists @log
  end
end
