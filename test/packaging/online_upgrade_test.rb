# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "stringio"
require_relative "../../packaging/upgrade/upgrader"

class ValpoPackagingOnlineUpgradeTest < Minitest::Test
  class Host < ValpoHostUpgrade
    attr_accessor :releases, :machine, :failure, :contents
    attr_reader :applied, :commands

    def initialize(root:, out:)
      super
      FileUtils.mkdir_p(@prefix)
      FileUtils.mkdir_p(@state)
      File.write(File.join(@prefix, "release.json"), JSON.generate(version: "0.1.1"))
      @machine = "x86_64"
      @commands = []
      @contents = {}
    end

    def apply(**options)
      raise Error, "Artifact SHA-256 mismatch" unless Digest::SHA256.file(options[:archive]).hexdigest == options[:sha256]
      @applied = options
      raise "Staging is not private" unless File.stat(File.dirname(options[:archive])).mode & 0o777 == 0o700
    end

    def run(*args, **)
      @commands << args
      return machine if args.first == "uname"
      raise Error, "Interrupted download" if failure == :download && args.any? { it.include?("/assets/") }
      endpoint = args.find { it.start_with?("repos/") }
      return contents.fetch(endpoint.split("/").last.to_i) if endpoint.include?("/assets/")
      return JSON.generate(releases.first) if endpoint.include?("/tags/")
      JSON.generate([releases])
    end
  end

  def setup
    @root = Dir.mktmpdir
    @out = StringIO.new
    @host = Host.new(root: @root, out: @out)
    @host.releases = [release("0.1.2")]
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def release(version, **overrides)
    files = {}
    %w[amd64 arm64].each do |arch|
      %w[tar.zst spdx.json provenance.intoto.jsonl sbom.intoto.jsonl].each do
        files["valpo-#{version}-linux-#{arch}.#{it}"] = "artifact #{version} #{arch} #{it}"
      end
    end
    files["SHA256SUMS"] = files.map { |name, data| "#{Digest::SHA256.hexdigest(data)}  ./#{name}\n" }.join
    assets = files.map do |name, data|
      id = @host.contents.size + 1
      @host.contents[id] = data
      {"id" => id, "name" => name, "state" => "uploaded", "size" => data.bytesize}
    end
    {"tag_name" => "v#{version}", "draft" => false, "published_at" => "2026-09-05", "immutable" => true,
     "prerelease" => version.include?("-"), "assets" => assets}.merge(overrides.transform_keys(&:to_s))
  end

  def test_automatic_selection_uses_version_order_and_ignores_drafts_and_previews
    @host.releases = [release("0.1.3"), release("0.1.10"), release("0.2.0-rc.1"), release("1.0.0", draft: true)]
    @host.update
    assert_match(/0.1.10-linux-amd64/, @host.applied[:archive])
    assert_equal "stable", @host.applied[:channel]
    refute_path_exists @host.applied[:archive]
    assert @host.commands.any? { it.include?("--paginate") }
  end

  def test_preview_and_arm64_and_explicit_tag
    @host.releases = [release("0.2.0-rc.2")]
    @host.machine = "aarch64"
    @host.update(tag: "v0.2.0-rc.2", channel: "preview")
    assert_match(/0.2.0-rc.2-linux-arm64/, @host.applied[:archive])
  end

  def test_no_newer_version_is_success_without_downloads
    @host.releases = [release("0.1.1"), release("0.1.0")]
    @host.update
    assert_includes @out.string, "Already up to date"
    assert_nil @host.applied
    refute @host.commands.any? { it.include?("Accept: application/octet-stream") }
  end

  def test_invalid_candidates_fail_before_applying
    [release("0.1.2", immutable: false), release("0.1.2", assets: []), release("0.1.2", draft: true),
      release("0.1.2", published_at: nil), release("0.2.0-rc.1"), release("0.1.0")].each do |candidate|
      @host.releases = [candidate]
      assert_raises(ValpoHostUpgrade::Error) { @host.update(tag: candidate["tag_name"]) }
      assert_nil @host.applied
    end
  end

  def test_unsupported_architecture_and_invalid_tag
    @host.machine = "s390x"
    assert_raises(ValpoHostUpgrade::Error) { @host.update }
    assert_raises(ValpoHostUpgrade::Error) { @host.update(tag: "../main") }
    assert_nil @host.applied
  end

  def test_interrupted_download_is_cleaned_up
    @host.failure = :download
    assert_raises(ValpoHostUpgrade::Error) { @host.update }
    assert_empty Dir[File.join(@root, "var/lib/valpo-updater/download-*")]
    assert_nil @host.applied
  end

  def test_checksum_mismatch_and_truncated_download
    asset = @host.releases.first["assets"].first
    original = @host.contents[asset["id"]]
    @host.contents[asset["id"]] = "x" * original.bytesize
    assert_match(/SHA-256/, assert_raises(ValpoHostUpgrade::Error) { @host.update }.message)
    @host.contents[asset["id"]] = "x"
    assert_match(/Incomplete/, assert_raises(ValpoHostUpgrade::Error) { @host.update }.message)
    assert_nil @host.applied
  end

  def test_semantic_prerelease_ordering
    versions = %w[1.0.0-1 1.0.0-alpha 1.0.0-alpha.2 1.0.0-alpha.10 1.0.0-rc.1 1.0.0]
    parsed = versions.map { @host.release_version("v#{it}") }
    assert_equal versions, parsed.reverse.sort.map(&:to_s)
    assert_nil @host.release_version("v1.0.0-01")
  end

  def test_online_development_channel_requires_explicit_choice
    assert_raises(ValpoHostUpgrade::Error) { @host.update(channel: "development") }
  end

  def test_exact_tag_provenance_failure_precedes_extraction
    archive = File.join(@root, "valpo-0.1.2-linux-amd64.tar.zst")
    File.write(archive, "test")
    host = ValpoHostUpgrade.new(root: @root)
    calls = []
    command = lambda do |*args|
      calls << args
      return "x86_64" if args.first == "uname"
      raise ValpoHostUpgrade::Error, "wrong-tag provenance"
    end
    host.stub(:run, command) do
      assert_raises(ValpoHostUpgrade::Error) { host.stage(archive, Digest::SHA256.file(archive).hexdigest, "stable") }
    end
    assert_includes calls.last, "refs/tags/v0.1.2"
    assert_includes calls.last, "holamendi/valpo/.github/workflows/release-artifacts.yml"
    refute_path_exists File.join(@root, "opt/valpo/releases/0.1.2")
  end
end
