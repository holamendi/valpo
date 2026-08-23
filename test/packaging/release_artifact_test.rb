# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "test_helper"
require "tmpdir"
require "toml-rb"

class ValpoPackagingReleaseArtifactTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BUILD_SCRIPT = File.join(ROOT, "packaging/release/build.sh")
  SMOKE_SCRIPT = File.join(ROOT, "packaging/release/smoke.sh")
  SBOM_SCRIPT = File.join(ROOT, "packaging/release/sbom.sh")
  SMOKE_CONTAINER_SCRIPT = File.join(ROOT, "packaging/release/smoke_container.sh")
  LAUNCHER = File.join(ROOT, "packaging/release/launcher.sh")
  MIGRATE = File.join(ROOT, "exe/valpo-migrate")
  DOCKERFILE = File.join(ROOT, "packaging/release/Dockerfile")
  SMOKE_DOCKERFILE = File.join(ROOT, "packaging/release/Smoke.Dockerfile")
  WORKFLOW = File.join(ROOT, ".github/workflows/release-artifacts.yml")

  def test_release_commands_are_executable_and_expose_help
    [BUILD_SCRIPT, SMOKE_SCRIPT, SBOM_SCRIPT, SMOKE_CONTAINER_SCRIPT, LAUNCHER, MIGRATE].each do
      assert File.executable?(it), "#{it} must be executable"
    end

    [BUILD_SCRIPT, SMOKE_SCRIPT, SBOM_SCRIPT].each do
      stdout, stderr, status = Open3.capture3("bash", it, "--help")

      assert status.success?, "#{it}\n#{stderr}"
      assert_includes stdout, "Usage:"
    end
  end

  def test_build_rejects_missing_and_unsupported_architectures_before_using_docker
    _stdout, stderr, status = Open3.capture3("bash", BUILD_SCRIPT)
    refute status.success?
    assert_includes stderr, "--architecture is required"

    _stdout, stderr, status = Open3.capture3(
      "bash", BUILD_SCRIPT, "--architecture", "s390x", "--output-dir", "dist"
    )
    refute status.success?
    assert_includes stderr, "Unsupported architecture: s390x"
  end

  def test_build_rejects_a_tag_that_does_not_match_release_metadata
    Dir.mktmpdir("valpo-release-build-test") do
      docker = File.join(it, "docker")
      File.write(docker, "#!/bin/sh\nexit 99\n")
      FileUtils.chmod(0o755, docker)
      path = [it, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(File::PATH_SEPARATOR)

      _stdout, stderr, status = Open3.capture3(
        {"PATH" => path},
        "bash",
        BUILD_SCRIPT,
        "--architecture",
        "amd64",
        "--output-dir",
        it,
        "--expected-tag",
        "v9.9.9"
      )

      refute status.success?
      assert_includes stderr, "does not match v#{Valpo::VERSION}"
    end
  end

  def test_mise_lock_covers_both_precompiled_linux_ruby_architectures
    mise_config = TomlRB.parse(File.read(File.join(ROOT, ".mise.toml")))
    assert_equal false, mise_config.dig("settings", "ruby", "compile")
    assert_equal true, mise_config.dig("settings", "ruby", "github_attestations")

    lock = TomlRB.parse(File.read(File.join(ROOT, "mise.lock")))
    ruby_entries = lock.dig("tools", "ruby")
    assert_equal 1, ruby_entries.size
    ruby = ruby_entries.fetch(0)
    assert_equal "4.0.5", ruby.fetch("version")

    {
      "platforms.linux-x64" => "ruby-4.0.5.x86_64_linux.tar.gz",
      "platforms.linux-arm64" => "ruby-4.0.5.arm64_linux.tar.gz"
    }.each do |platform, filename|
      asset = ruby.fetch(platform)
      assert asset.fetch("url").end_with?(filename)
      assert_match(/\Asha256:[0-9a-f]{64}\z/, asset.fetch("checksum"))
      assert_equal "github-attestations", asset.fetch("provenance")
    end
  end

  def test_builder_pins_tools_and_enforces_pruning_content_and_size_contracts
    build_script = File.read(BUILD_SCRIPT)
    dockerfile = File.read(DOCKERFILE)

    assert_includes build_script, "RUBY_VERSION=${runtime_ruby_version}"
    refute_includes build_script, "RUBY_VERSION=${code_version}"
    assert_includes dockerfile, "MISE_VERSION=2026.6.0"
    assert_includes dockerfile, "MISE_RUBY_COMPILE=false"
    assert_includes dockerfile, "mise install --locked"
    assert_includes dockerfile, "ruby-build|building ruby|compiling ruby"
    gem_stage = dockerfile[/FROM ruby-runtime AS gems.*?(?=FROM ruby-runtime AS build)/m]
    artifact_stage = dockerfile[/FROM ruby-runtime AS build.*?(?=FROM scratch AS artifact)/m]
    assert_includes gem_stage, "build-essential"
    refute_includes artifact_stage, "build-essential"
    assert_match(/mise_sha256="[0-9a-f]{64}"/, dockerfile)
    assert_match(/pack_sha256="[0-9a-f]{64}"/, dockerfile)
    assert_includes dockerfile, "bundle \"_${BUNDLER_VERSION}_\" install --standalone=default"
    assert_includes dockerfile, "development:test"
    assert_includes dockerfile, "share/ri"
    assert_includes dockerfile, "mise_rubygems_plugin"
    assert_includes dockerfile, "-name '*.a' -delete"
    assert_includes dockerfile, "-name cache -o -name doc"
    assert_includes dockerfile, "275 * 1024"
    assert_includes dockerfile, "75 * 1024 * 1024"
    assert_includes dockerfile, "--sort=name"
    assert_includes dockerfile, "--mtime=\"@${SOURCE_DATE_EPOCH}\""
    assert_includes dockerfile, "zstd -10 -T1"
    assert_includes dockerfile, 'archive="valpo-${VALPO_VERSION}-linux-${TARGETARCH}.tar.zst"'
    assert_includes dockerfile, '-C / "opt/valpo/releases/${VALPO_VERSION}"'

    %w[Gemfile.lock LICENSE db exe lib packaging release.json valpo.gemspec].each do
      assert_match(/\b#{Regexp.escape(it)}\b/, dockerfile)
    end
  end

  def test_launchers_are_release_local_and_cover_every_process
    launcher = File.read(LAUNCHER)

    %w[valpo valpo-api valpo-maintenance valpo-migrate valpo-worker].each do
      assert_includes launcher, it
    end
    assert_includes launcher, 'release_root="$(cd "$(dirname "$launcher_path")/.." && pwd)"'
    assert_includes launcher, 'export RUBYLIB="${release_root}/bundle"'
    assert_includes launcher, 'exec "${release_root}/runtime/ruby/bin/ruby"'
    refute_includes launcher, "mise exec"
  end

  def test_migration_executable_migrates_a_fresh_database_without_rake
    Dir.mktmpdir("valpo-release-migrate") do
      database_path = File.join(it, "valpo.sqlite3")
      environment = {
        "BUNDLE_GEMFILE" => nil,
        "VALPO_CONFIG" => nil,
        "VALPO_ENV" => "production",
        "VALPO_DATABASE_PATH" => database_path
      }

      2.times do
        stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, MIGRATE)

        assert status.success?, stderr
        assert_includes stdout, "schema #{Valpo::ReleaseMetadata.current.schema_target}"
      end

      database = Sequel.sqlite(database_path)
      assert_equal Valpo::ReleaseMetadata.current.schema_target, Valpo::SchemaInfo.current(db: database)
      database.disconnect
    end
  end

  def test_smoke_test_checks_archive_safety_runtime_contents_and_offline_health
    dockerfile = File.read(SMOKE_DOCKERFILE)
    smoke = File.read(SMOKE_CONTAINER_SCRIPT)

    assert_includes dockerfile, "RUN --network=none"
    assert_includes dockerfile, "Unsafe archive entry"
    assert_includes dockerfile, "Archive entry is outside"
    assert_includes smoke, "RUBY_VERSION"
    assert_includes smoke, "RUBY_PLATFORM"
    assert_includes smoke, "pack\" version"
    assert_includes smoke, "not found"
    assert_includes smoke, "valpo-migrate"
    assert_includes smoke, "/health"
    assert_includes smoke, "$LOADED_FEATURES"
    assert_includes smoke, "Development gem leaked"
    assert_includes smoke, "mise runtime files leaked"
  end

  def test_release_workflow_uses_native_jobs_and_pinned_supply_chain_tools
    workflow = File.read(WORKFLOW)

    assert_includes workflow, '"runner":"ubuntu-26.04"'
    assert_includes workflow, '"runner":"ubuntu-26.04-arm"'
    assert_includes workflow, "actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8"
    assert_includes workflow, "actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6"
    assert_includes workflow, "SHA256SUMS"
    assert_includes workflow, ".spdx.json"
    assert_includes workflow, "Delete transfer artifacts"
    assert_includes workflow, "actions/artifacts/${artifact_id}"
    refute_includes workflow.downcase, "qemu"
    refute_includes workflow, "gh release"
  end
end
