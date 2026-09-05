# frozen_string_literal: true

require "test_helper"

class ValpoSourcesPreflightTest < Minitest::Test
  COMMIT = "a" * 40

  def test_uses_remote_head_and_default_build_paths
    fetcher = FakeFetcher.new
    result = nil
    context_directory = false

    Valpo::Sources::Preflight.new(fetcher:).with_checkout(
      provider: "github",
      repository: "acme/backend"
    ) do
      result = it
      context_directory = File.directory?(it.context)
    end

    assert_equal "HEAD", fetcher.ref
    assert_equal COMMIT, result.commit
    assert_equal "dockerfile", result.strategy
    assert_equal "Dockerfile", File.basename(result.dockerfile)
    assert context_directory
  end

  def test_auto_uses_buildpacks_when_the_context_has_no_dockerfile
    fetcher = FakeFetcher.new(dockerfile: false)
    result = nil

    Valpo::Sources::Preflight.new(fetcher:).with_checkout(
      provider: "github",
      repository: "acme/backend"
    ) { result = it }

    assert_equal "buildpack", result.strategy
    assert_nil result.dockerfile
  end

  def test_explicit_buildpack_ignores_a_repository_dockerfile
    result = nil

    Valpo::Sources::Preflight.new(fetcher: FakeFetcher.new).with_checkout(
      provider: "github",
      repository: "acme/backend",
      strategy: "buildpack"
    ) { result = it }

    assert_equal "buildpack", result.strategy
    assert_nil result.dockerfile
  end

  def test_rejects_missing_and_escaping_build_paths
    preflight = Valpo::Sources::Preflight.new(fetcher: FakeFetcher.new)
    error = assert_raises Valpo::ValidationError do
      preflight.with_checkout(
        provider: "github",
        repository: "acme/backend",
        strategy: "dockerfile",
        dockerfile: "missing"
      ) { flunk "checkout should not be yielded" }
    end
    assert_match "Build file does not exist", error.message

    error = assert_raises Valpo::ValidationError do
      preflight.with_checkout(
        provider: "github",
        repository: "acme/backend",
        context: ".."
      ) { flunk "checkout should not be yielded" }
    end
    assert_match "stay within", error.message
  end

  def test_reuses_one_source_checkout_for_multiple_build_validations
    fetcher = FakeFetcher.new
    preflight = Valpo::Sources::Preflight.new(fetcher:)
    result = nil

    preflight.with_source_checkout(provider: "github", repository: "acme/backend") do
      source = it
      preflight.validate_checkout(source:, strategy: "dockerfile")
      result = preflight.validate_checkout(source:, strategy: "auto", context: ".")
    end

    assert_equal 1, fetcher.calls
    assert_equal COMMIT, result.commit
  end

  def test_source_checkout_reports_context_and_dockerfile_errors_without_paths
    preflight = Valpo::Sources::Preflight.new(fetcher: FakeFetcher.new)
    preflight.with_source_checkout(provider: "github", repository: "acme/backend") do
      source = it
      error = assert_raises(Valpo::ValidationError) do
        preflight.validate_checkout(source:, strategy: "dockerfile", context: "missing")
      end
      assert_match "Build directory does not exist: missing", error.message
      refute_match %r{/private/tmp|/var/folders}, error.message

      error = assert_raises(Valpo::ValidationError) do
        preflight.validate_checkout(source:, strategy: "dockerfile", dockerfile: "missing")
      end
      assert_match "Build file does not exist: missing", error.message
      refute_match %r{/private/tmp|/var/folders}, error.message
    end
  end

  def test_rejects_an_invalid_commit_from_the_fetcher
    error = assert_raises Valpo::ValidationError do
      Valpo::Sources::Preflight.new(fetcher: FakeFetcher.new(commit: "wat")).with_checkout(
        provider: "github",
        repository: "acme/backend"
      ) { flunk "checkout should not be yielded" }
    end
    assert_match "invalid commit SHA", error.message
  end

  class FakeFetcher
    attr_reader :ref

    def initialize(commit: COMMIT, dockerfile: true)
      @commit = commit
      @dockerfile = dockerfile
      @calls = 0
    end

    attr_reader :calls

    def checkout(destination:, ref:, **)
      @calls += 1
      @ref = ref
      File.write(File.join(destination, "Dockerfile"), "FROM scratch\n") if @dockerfile
      @commit
    end
  end
end
