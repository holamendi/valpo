# frozen_string_literal: true

require "test_helper"

class ValpoAPIV1ResourceContractsTest < Minitest::Test
  CONTRACTS = {
    create_service: Valpo::API::V1::Services::CreateContract,
    create_api_credential: Valpo::API::V1::APICredentials::CreateContract,
    environment_query: Valpo::API::V1::Services::EnvironmentQueryContract,
    event_list_query: Valpo::API::V1::Jobs::EventListQueryContract,
    job_list_query: Valpo::API::V1::Jobs::ListQueryContract,
    set_environment_variable: Valpo::API::V1::Services::SetEnvironmentVariableContract,
    tail_query: Valpo::API::V1::Services::TailQueryContract,
    update_service: Valpo::API::V1::Services::UpdateContract
  }.freeze

  def test_create_service_preserves_native_json_types_and_nullable_values
    result = contract(:create_service).call(
      name: "web",
      type: "web",
      command: ["bin/server"],
      internal_port: 3000,
      healthcheck_path: nil,
      deploy: false
    )

    assert result.success?, result.errors.to_h.inspect
    assert_equal 3000, result[:internal_port]
    assert_equal false, result[:deploy]
    assert_nil result[:healthcheck_path]
  end

  def test_create_service_rejects_missing_unknown_and_nested_unknown_keys
    missing = contract(:create_service).call(type: "web")
    assert_equal [[:name]], missing.errors.map(&:path)

    unknown = contract(:create_service).call(name: "web", type: "web", port: 3000)
    assert_includes unknown.errors.map(&:path), [:port]

    nested = contract(:create_service).call(
      name: "web",
      type: "web",
      source: {provider: "github", repository: "acme/web", token: "secret"}
    )
    assert_includes nested.errors.map(&:path), [:source, :token]
  end

  def test_create_service_rejects_coercible_values_port_bounds_and_bad_commands
    refute contract(:create_service).call(name: "web", type: "web", deploy: "false").success?
    refute contract(:create_service).call(name: "web", type: "web", internal_port: "3000").success?
    refute contract(:create_service).call(name: "web", type: "web", internal_port: 0).success?
    refute contract(:create_service).call(name: "web", type: "web", internal_port: 65_536).success?
    refute contract(:create_service).call(name: "web", type: "web", command: [""]).success?
    refute contract(:create_service).call(name: "web", type: "web", command: ["   "]).success?
    refute contract(:create_service).call(name: "web", type: "web", command: "bin/server").success?
  end

  def test_update_contract_accepts_explicit_clears
    result = contract(:update_service).call(command: [], internal_port: nil, healthcheck_path: nil)

    assert result.success?, result.errors.to_h.inspect
    assert_equal [], result[:command]
    assert result.to_h.key?(:internal_port)
    assert result.to_h.key?(:healthcheck_path)
  end

  def test_healthcheck_and_nested_shapes_are_strict
    refute contract(:update_service).call(healthcheck_path: "health").success?
    refute contract(:update_service).call(source: []).success?
    refute contract(:update_service).call(build: {dockerfile: 1}).success?
    refute contract(:update_service).call(source: {}).success?
    refute contract(:update_service).call(build: {}).success?
  end

  def test_build_strategy_accepts_only_public_values
    assert contract(:create_service).call(
      name: "web",
      type: "web",
      source: {provider: "github", repository: "acme/web"},
      build: {strategy: "buildpack"}
    ).success?
    refute contract(:create_service).call(
      name: "web",
      type: "web",
      build: {strategy: "railpack"}
    ).success?
  end

  def test_query_contracts_coerce_integers_but_accept_only_literal_booleans
    tail = contract(:tail_query).call("tail" => "20")
    assert tail.success?
    assert_equal 20, tail[:tail]

    refute contract(:tail_query).call("tail" => "1.5").success?
    refute contract(:tail_query).call("tail" => "0").success?
    assert contract(:environment_query).call("reveal" => "true").success?
    assert contract(:environment_query).call("reveal" => "false").success?
    refute contract(:environment_query).call("reveal" => "1").success?
    refute contract(:environment_query).call("unknown" => "true").success?

    job_list = contract(:job_list_query).call("limit" => "500")
    assert job_list.success?
    assert_equal 500, job_list[:limit]
    refute contract(:job_list_query).call("limit" => "501").success?
    refute contract(:job_list_query).call("limit" => "0").success?

    events = contract(:event_list_query).call("after" => "evt_123", "limit" => "200")
    assert events.success?
    assert_equal "evt_123", events[:after]
    refute contract(:event_list_query).call("after" => "").success?
  end

  def test_environment_and_api_credential_contracts_are_strict
    environment = contract(:set_environment_variable).call(value: "", sensitive: true)
    assert environment.success?, environment.errors.to_h.inspect
    refute contract(:set_environment_variable).call(value: "secret", sensitive: "true").success?

    credential = contract(:create_api_credential).call(name: "operator", scopes: %w[read write])
    assert credential.success?, credential.errors.to_h.inspect
    refute contract(:create_api_credential).call(name: "operator", scopes: ["unknown"]).success?
  end

  private

  def contract(name)
    CONTRACTS.fetch(name).new
  end
end
