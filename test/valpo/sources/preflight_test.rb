# frozen_string_literal: true

require "test_helper"

class ValpoSourcesPreflightTest < Minitest::Test
  COMMIT = "a" * 40

  def test_uses_remote_head_and_default_build_paths
    fetcher = FakeFetcher.new
    result = nil
    context_directory = false

    Valpo::Sources::Preflight.new(fetcher: fetcher).with_checkout(
      provider: "github",
      repository: "acme/backend"
    ) do |checkout|
      result = checkout
      context_directory = File.directory?(checkout.context)
    end

    assert_equal "HEAD", fetcher.ref
    assert_equal COMMIT, result.commit
    assert_equal "Dockerfile", File.basename(result.dockerfile)
    assert context_directory
  end

  def test_rejects_missing_and_escaping_build_paths
    preflight = Valpo::Sources::Preflight.new(fetcher: FakeFetcher.new)
    error = assert_raises Valpo::ValidationError do
      preflight.with_checkout(
        provider: "github",
        repository: "acme/backend",
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

    def initialize(commit: COMMIT)
      @commit = commit
    end

    def checkout(destination:, ref:, **)
      @ref = ref
      File.write(File.join(destination, "Dockerfile"), "FROM scratch\n")
      @commit
    end
  end
end
