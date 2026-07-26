# frozen_string_literal: true

require "test_helper"

class ValpoSourcesGitHubTest < Minitest::Test
  Source = Data.define(:repository, :ref)

  def test_fetches_over_https_without_putting_the_token_in_command_arguments
    runner = FakeRunner.new
    client = Valpo::Sources::GitHub.new(
      token: "github-secret",
      runner:,
      askpass_path: "/opt/valpo/exe/valpo-git-askpass"
    )

    commit = client.checkout(
      source: Source.new(repository: "acme/backend", ref: "main"),
      destination: "/tmp/checkout",
      ref: "feature/manual-deploy"
    )

    assert_equal FakeRunner::COMMIT, commit
    refute runner.calls.any? { |_environment, command| command.join(" ").include?("github-secret") }
    fetch_environment, fetch_command = runner.calls.find { |_environment, command| command.include?("fetch") }
    assert_equal "github-secret", fetch_environment.fetch("VALPO_GIT_ASKPASS_TOKEN")
    assert_equal "force", fetch_environment.fetch("GIT_ASKPASS_REQUIRE")
    assert_equal ["origin", "feature/manual-deploy"], fetch_command.last(2)
    remote_command = runner.calls.find { |_environment, command| command.include?("remote") }.last
    assert_includes remote_command, "https://github.com/acme/backend.git"
  end

  def test_rejects_non_github_repository_names_before_running_git
    runner = FakeRunner.new
    error = assert_raises Valpo::ValidationError do
      Valpo::Sources::GitHub.new(runner:).checkout(
        source: Source.new(repository: "https://evil.example/repo", ref: "main"),
        destination: "/tmp/checkout"
      )
    end

    assert_match "owner/repository", error.message
    assert_empty runner.calls
  end

  def test_resolves_callable_tokens_for_each_checkout
    token = "first-token"
    runner = FakeRunner.new
    client = Valpo::Sources::GitHub.new(token: -> { token }, runner:)
    source = Source.new(repository: "acme/backend", ref: "main")

    client.checkout(source:, destination: "/tmp/first")
    token = "second-token"
    client.checkout(source:, destination: "/tmp/second")

    fetches = runner.calls.select { |_environment, command| command.include?("fetch") }
    assert_equal %w[first-token second-token], fetches.map { |environment, _command| environment.fetch("VALPO_GIT_ASKPASS_TOKEN") }
  end

  def test_resolves_repository_scoped_tokens
    repositories = []
    runner = FakeRunner.new
    client = Valpo::Sources::GitHub.new(
      token: -> {
        repositories << it
        "installation-token"
      },
      runner:
    )

    client.checkout(
      source: Source.new(repository: "acme/backend", ref: "main"),
      destination: "/tmp/repository-token"
    )

    assert_equal ["acme/backend"], repositories
  end

  def test_reports_inaccessible_repositories_invalid_credentials_and_missing_refs
    cases = {
      "Repository not found" => nil,
      "Authentication failed" => "invalid-secret",
      "couldn't find remote ref missing" => "valid-looking-secret"
    }

    cases.each do |detail, token|
      error = assert_raises Valpo::ValidationError do
        Valpo::Sources::GitHub.new(token:, runner: FakeRunner.new(fetch_error: detail)).checkout(
          source: Source.new(repository: "acme/private", ref: "missing"),
          destination: "/tmp/checkout"
        )
      end

      assert_match "GitHub fetch failed", error.message
      assert_match detail, error.message
      refute_includes error.message, token if token
    end
  end

  class FakeRunner
    COMMIT = "a" * 40

    attr_reader :calls

    def initialize(fetch_error: nil)
      @calls = []
      @fetch_error = fetch_error
    end

    def capture(environment, command)
      calls << [environment, command]
      if @fetch_error && command.include?("fetch")
        return {stdout: "", stderr: @fetch_error, status: 128, success: false}
      end

      stdout = command.include?("rev-parse") ? "#{COMMIT}\n" : ""
      {stdout:, stderr: "", status: 0, success: true}
    end
  end
end
