# frozen_string_literal: true

require "json"
require "openssl"
require "test_helper"

class ValpoGitHubWebhookTest < Minitest::Test
  include ValpoTestDatabase

  def test_verifies_signatures_enqueues_pushes_and_deduplicates_deliveries
    source, service = configured_auto_deploy
    body = JSON.generate(
      "ref" => "refs/heads/main",
      "after" => "a" * 40,
      "repository" => {"full_name" => source.repository, "default_branch" => "main"}
    )
    webhook = Valpo::GitHub::Webhook.new(credentials: FakeCredentials.new("hook-secret"))
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "hook-secret", body)}"

    assert webhook.valid_signature?(body, signature)
    result = webhook.receive(event: "push", delivery_id: "delivery-1", body:)
    duplicate = webhook.receive(event: "push", delivery_id: "delivery-1", body:)

    assert_equal [Valpo::Job.first.id], result.fetch("jobs")
    assert_equal service.id, Valpo::Job.first.payload.fetch("service_id")
    assert_equal "a" * 40, Valpo::Job.first.payload.fetch("ref")
    assert_equal true, duplicate.fetch("duplicate")
    assert_equal 1, Valpo::Job.count
    assert_equal 1, Valpo::GitHubWebhookDelivery.first.jobs_count
  end

  def test_rejects_invalid_signatures
    webhook = Valpo::GitHub::Webhook.new(credentials: FakeCredentials.new("hook-secret"))

    refute webhook.valid_signature?("{}", "sha256=invalid")
    refute webhook.valid_signature?("{}", nil)
  end

  def test_ignores_branch_deletion_pushes
    source, = configured_auto_deploy
    body = JSON.generate(
      "ref" => "refs/heads/main",
      "after" => "0" * 40,
      "deleted" => true,
      "repository" => {"full_name" => source.repository, "default_branch" => "main"}
    )

    result = Valpo::GitHub::Webhook.new(credentials: FakeCredentials.new("hook-secret")).receive(
      event: "push",
      delivery_id: "delivery-delete",
      body:
    )

    assert_equal [], result.fetch("jobs")
    assert_equal 0, Valpo::Job.count
  end

  private

  def configured_auto_deploy
    project = create_project
    service = create_app_service(project:)
    source = Valpo::Source.create(
      project_id: project.id,
      name: "web",
      provider: "github",
      repository: "acme/backend",
      ref: "main",
      auto_deploy: true
    )
    build = Valpo::BuildTarget.create(
      project_id: project.id,
      source_id: source.id,
      name: "web",
      strategy: "dockerfile",
      dockerfile: "Dockerfile"
    )
    Valpo::AppServiceConfig[service.id].update(build_target_id: build.id)
    [source, service]
  end

  class FakeCredentials
    def initialize(secret)
      @secret = secret
    end

    def read
      {"webhook_secret" => @secret}
    end
  end
end
