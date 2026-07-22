# frozen_string_literal: true

require "test_helper"

class ValpoCLIPayloadBuildersTest < Minitest::Test
  def test_service_create_builds_source_and_runtime_payload
    payload = Valpo::CLI::PayloadBuilders::ServiceCreate.call(
      name: "web",
      type: "web",
      command: ["bin/server"],
      port: "3000",
      source: "github:acme/backend",
      ref: "main",
      deploy: true
    )

    assert_equal 3000, payload.fetch("internal_port")
    assert_equal({"provider" => "github", "repository" => "acme/backend", "ref" => "main"}, payload.fetch("source"))
    assert_equal({"dockerfile" => "Dockerfile", "context" => "."}, payload.fetch("build"))
    assert_equal true, payload.fetch("deploy")
  end

  def test_service_create_rejects_type_and_source_option_mismatches
    error = assert_raises(Valpo::CLI::UsageError) do
      Valpo::CLI::PayloadBuilders::ServiceCreate.call(name: "database", type: "postgres", command: [])
    end
    assert_match "command", error.message

    assert_raises(Valpo::CLI::UsageError) do
      Valpo::CLI::PayloadBuilders::ServiceCreate.call(name: "web", type: "web", deploy: true)
    end
    assert_raises(Valpo::CLI::UsageError) do
      Valpo::CLI::PayloadBuilders::ServiceCreate.call(name: "cache", type: "redis", source: "github:acme/cache")
    end
  end

  def test_service_update_encodes_explicit_clears
    payload = Valpo::CLI::PayloadBuilders::ServiceUpdate.call(
      clear_command: true,
      clear_port: true,
      clear_healthcheck: true
    )

    assert_equal [], payload.fetch("command")
    assert payload.key?("internal_port")
    assert_nil payload.fetch("internal_port")
    assert payload.key?("healthcheck_path")
    assert_nil payload.fetch("healthcheck_path")
  end

  def test_service_update_rejects_conflicts_and_empty_updates
    assert_raises(Valpo::CLI::UsageError) do
      Valpo::CLI::PayloadBuilders::ServiceUpdate.call(command: ["bin/server"], clear_command: true)
    end
    assert_raises(Valpo::CLI::UsageError) do
      Valpo::CLI::PayloadBuilders::ServiceUpdate.call(port: "3000", clear_port: true)
    end
    assert_raises(Valpo::CLI::UsageError) do
      Valpo::CLI::PayloadBuilders::ServiceUpdate.call
    end
  end
end
