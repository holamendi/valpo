# frozen_string_literal: true

require "test_helper"
require "yaml"

class ValpoAPIOpenAPITest < Minitest::Test
  include ValpoTestDatabase

  HTTP_METHODS = %w[get post put patch delete].freeze
  SPEC_PATH = File.join(Valpo.root, "docs", "openapi.yaml")
  BODY_CONTRACTS = {
    Valpo::API::V1::APICredentials::CreateContract => "CreateAPICredentialRequest",
    Valpo::API::V1::GitHub::CreateSetupContract => "CreateGitHubAppSetupRequest",
    Valpo::API::V1::GitHub::StorePersonalAccessTokenContract => "StoreGitHubPersonalAccessTokenRequest",
    Valpo::API::V1::Projects::ApplyContract => "ApplyProjectRequest",
    Valpo::API::V1::Projects::CreateContract => "CreateProjectRequest",
    Valpo::API::V1::Services::BindDependencyContract => "BindDependencyRequest",
    Valpo::API::V1::Services::CreateContract => "CreateServiceRequest",
    Valpo::API::V1::Services::CreateDomainContract => "CreateDomainRequest",
    Valpo::API::V1::Services::DeployContract => "DeployServiceRequest",
    Valpo::API::V1::Services::SetEnvironmentVariableContract => "SetEnvironmentVariableRequest",
    Valpo::API::V1::Services::UpdateContract => "UpdateServiceRequest",
    Valpo::API::V1::System::ConfigureAppDomainContract => "ConfigureAppDomainRequest",
    Valpo::API::V1::System::MaintainStorageContract => "MaintainStorageRequest"
  }.freeze
  QUERY_CONTRACTS = {
    Valpo::API::V1::GitHub::SetupQueryContract => "showGitHubAppManifest",
    Valpo::API::V1::GitHub::CallbackQueryContract => "completeGitHubAppSetup",
    Valpo::API::V1::GitHub::InstallationQueryContract => "confirmGitHubAppInstallation",
    Valpo::API::V1::Jobs::EventListQueryContract => "listJobEvents",
    Valpo::API::V1::Jobs::ListQueryContract => "listJobs",
    Valpo::API::V1::Projects::LogsQueryContract => "getProjectLogs",
    Valpo::API::V1::Services::DeleteQueryContract => "deleteService",
    Valpo::API::V1::Services::EnvironmentQueryContract => "getServiceEnvironment",
    Valpo::API::V1::Services::ListQueryContract => "listServices",
    Valpo::API::V1::Services::TailQueryContract => "getServiceLogs"
  }.freeze
  CONTRACT_NAMESPACES = [
    Valpo::API::V1::APICredentials,
    Valpo::API::V1::GitHub,
    Valpo::API::V1::Jobs,
    Valpo::API::V1::Projects,
    Valpo::API::V1::Services,
    Valpo::API::V1::System
  ].freeze
  IDEMPOTENT_ENQUEUE_OPERATIONS = %w[
    applyProjectManifest deleteProject createService updateService deleteService restartService stopService
    bindServiceDependency unbindServiceDependency deployService rollbackService reconcileServiceEnvironment
    setServiceEnvironmentVariable deleteServiceEnvironmentVariable createServiceDomain verifyServiceDomain
    deleteServiceDomain configurePlatformDomain repairSystem maintainStorage verifySecrets rotateSecrets
  ].freeze

  def test_openapi_version_and_operation_ids
    assert_equal "3.1.0", spec.fetch("openapi")
    assert_equal Valpo::VERSION, spec.dig("info", "version")
    assert_equal "http", spec.dig("components", "securitySchemes", "bearerAuth", "type")
    assert_equal "bearer", spec.dig("components", "securitySchemes", "bearerAuth", "scheme")
    assert_instance_of Hash, spec.fetch("paths")
    assert_instance_of Hash, spec.dig("components", "schemas")
    ids = operations.map { |_route, operation| operation.fetch("operationId") }
    assert_equal ids.uniq.sort, ids.sort
    refute_empty ids
    operations.each do |route, operation|
      refute_empty operation.fetch("summary"), route
      refute_empty operation.fetch("responses"), route
    end
  end

  def test_every_local_reference_resolves
    references = collect_references(spec)
    refute_empty references
    references.each { resolve_reference(it) }
  end

  def test_every_enqueue_operation_documents_the_idempotency_header
    documented = operations.filter_map do |route, operation|
      path = route.split(" ", 2).last
      parameters = spec.fetch("paths").fetch(path).fetch("parameters", []) + operation.fetch("parameters", [])
      operation.fetch("operationId") if parameters.any? { it["$ref"] == "#/components/parameters/IdempotencyKey" }
    end

    assert_equal IDEMPOTENT_ENQUEUE_OPERATIONS.sort, documented.sort
  end

  def test_openapi_operations_exactly_match_standardized_route_comments
    documented = operations.map { |route, _operation| route }.sort
    assert_equal route_comments.sort, documented
  end

  def test_route_comments_are_immediately_above_terminal_matchers
    route_files.each do
      path = it
      lines = File.readlines(path)
      lines.each_with_index do |line, index|
        next unless (match = line.match(/# (GET|POST|PUT|PATCH|DELETE) (\/\S*) —/))

        matcher = lines[index + 1].to_s.strip
        expected = if match[2] == "/"
          "r.root"
        elsif match[1] == "GET"
          "r.get true"
        elsif match[1] == "POST"
          "r.post true"
        else
          "r.is do"
        end
        assert matcher.start_with?(expected), "#{relative_path(path)}:#{index + 2} must start with #{expected}"
      end
    end
  end

  def test_request_contract_matrix_covers_every_concrete_contract
    mapped = BODY_CONTRACTS.keys + QUERY_CONTRACTS.keys + [Valpo::API::V1::Contract::EmptyQuery]
    assert_equal request_contract_classes.map(&:name).sort, mapped.map(&:name).sort
    assert_equal [], Valpo::API::V1::Contract::EmptyQuery.new.schema.key_map.to_a
  end

  def test_body_contract_keys_required_fields_and_nested_shapes_match_openapi
    BODY_CONTRACTS.each do |contract_class, schema_name|
      contract = contract_class.new
      schema = component_schema(schema_name)

      assert_contract_key_map(contract, contract.schema.key_map, schema, schema_name:)
    end
  end

  def test_query_contract_keys_and_required_fields_match_openapi
    QUERY_CONTRACTS.each do |contract_class, operation_id|
      contract = contract_class.new
      parameters = query_parameters(operation_id)
      context = "#{contract_class.name} / #{operation_id}"

      assert_equal contract.schema.key_map.map(&:name).sort, parameters.map { it.fetch("name") }.sort, context
      assert_equal required_contract_keys(contract).sort,
        parameters.select { it.fetch("required", false) }.map { it.fetch("name") }.sort,
        context
    end
  end

  def test_representative_renderer_keys_strictly_match_response_schemas
    representative_renderings.each do |schema_name, outputs|
      schema = component_schema(schema_name)
      properties = schema.fetch("properties").keys.sort
      required = schema.fetch("required", []).sort
      emitted = outputs.flat_map(&:keys).map(&:to_s).uniq.sort

      assert_equal false, schema.fetch("additionalProperties"), schema_name
      assert_equal properties, emitted, schema_name
      outputs.each do
        keys = it.keys.map(&:to_s)
        assert_empty required - keys, "#{schema_name} renderer omitted required keys"
        assert_empty keys - properties, "#{schema_name} renderer emitted undocumented keys"
      end
    end
  end

  private

  def spec
    @spec ||= YAML.safe_load_file(SPEC_PATH, aliases: false)
  end

  def operations
    @operations ||= spec.fetch("paths").flat_map do |path, path_item|
      HTTP_METHODS.filter_map do
        operation = path_item[it]
        ["#{it.upcase} #{path}", operation] if operation
      end
    end
  end

  def operation(operation_id)
    spec.fetch("paths").each_value do |path_item|
      HTTP_METHODS.each do
        candidate = path_item[it]
        return [path_item, candidate] if candidate&.fetch("operationId") == operation_id
      end
    end
    flunk "OpenAPI operation not found: #{operation_id}"
  end

  def query_parameters(operation_id)
    path_item, operation = operation(operation_id)
    Array(path_item["parameters"]).concat(Array(operation["parameters"])).map { resolve_value(it) }
      .select { it.fetch("in") == "query" }
  end

  def request_contract_classes
    CONTRACT_NAMESPACES.flat_map do |namespace|
      namespace.constants(false).filter_map do
        value = namespace.const_get(it)
        value if value.is_a?(Class) && value < Valpo::API::V1::Contract
      end
    end + [Valpo::API::V1::Contract::EmptyQuery]
  end

  def assert_contract_key_map(contract, key_map, schema, schema_name:, prefix: [])
    context = "#{contract.class.name} / #{schema_name}"
    context += " / #{prefix.join(".")}" unless prefix.empty?
    assert_equal false, schema.fetch("additionalProperties"), context
    assert_equal key_map.map(&:name).sort, schema.fetch("properties").keys.sort, context
    assert_equal required_contract_keys(contract, prefix:).sort, schema.fetch("required", []).sort, context

    key_map.each do
      next unless it.respond_to?(:members)

      nested_schema = resolve_value(schema.fetch("properties").fetch(it.name))
      assert_contract_key_map(
        contract,
        it.members,
        nested_schema,
        schema_name:,
        prefix: prefix + [it.name]
      )
    end
  end

  def required_contract_keys(contract, prefix: [])
    input = prefix.reverse_each.reduce({}) { |value, key| {key.to_sym => value} }
    depth = prefix.length + 1
    contract.call(input).errors.map(&:path)
      .select { it.length == depth && it.first(prefix.length).map(&:to_s) == prefix }
      .map { it.last.to_s }
  end

  def component_schema(name)
    spec.dig("components", "schemas").fetch(name)
  end

  def resolve_value(value)
    reference = value["$ref"]
    return value unless reference

    reference.delete_prefix("#/").split("/").reduce(spec) do |resolved, component|
      resolved.fetch(component.gsub("~1", "/").gsub("~0", "~"))
    end
  end

  def representative_renderings
    project = create_project
    source = Valpo::Source.create(
      project_id: project.id,
      name: "backend",
      provider: "github",
      repository: "acme/backend",
      ref: "main"
    )
    build = Valpo::BuildTarget.create(
      project_id: project.id,
      source_id: source.id,
      name: "backend",
      dockerfile: "Dockerfile",
      context: "."
    )
    app = create_app_service(project:)
    Valpo::AppServiceConfig[app.id].update(build_target_id: build.id)
    managed = create_managed_service(project:)
    dependency = Valpo::ServiceDependency.create(
      service_id: app.id,
      dependency_service_id: managed.id,
      status: "active"
    )
    environment_variable = Valpo::ServiceEnvironmentVariable.new(
      service_id: app.id,
      name: "FEATURE_FLAG",
      sensitive: false
    )
    environment_variable.value = "enabled"
    environment_variable.save
    api_credential, = Valpo::APICredential.issue(name: "OpenAPI", scopes: %w[read write])
    release = create_release(
      service: app,
      build_strategy: "buildpack",
      build_metadata_json: JSON.generate(
        "dockerfile" => "Dockerfile",
        "builder" => "example/builder@sha256:abc",
        "buildpacks" => [],
        "processes" => []
      )
    )
    platform_domain = create_platform_domain
    domain = create_domain(service: app, platform_domain_id: platform_domain.id)
    job = Valpo::Jobs::Queue.new.enqueue("system_check", source: "openapi-test")
    event = Valpo::Jobs::Queue.new.events(job.id).first
    app_output = Valpo::API::V1::Services.render(app)
    managed_output = Valpo::API::V1::Services.render(managed)
    release_output = Valpo::API::V1::Services.render_release(release)
    project_output = Valpo::API::V1::Projects.render(project)
    environment_entry = Valpo::Services::Environment.entries_for_service(app.id, reveal: false).fetch(0)
    successful_log = {
      service_id: app.id,
      service_name: app.name,
      type: app.kind,
      stdout: "ready\n",
      stderr: ""
    }
    failed_log = {
      service_id: managed.id,
      service_name: managed.name,
      type: managed.kind,
      error: "container unavailable"
    }

    {
      "Project" => [project_output],
      "Source" => [Valpo::API::V1::Projects.render_source(source)],
      "BuildTarget" => [Valpo::API::V1::Projects.render_build_target(build)],
      "Service" => [app_output, managed_output],
      "AppConfiguration" => [app_output.fetch(:app)],
      "ManagedConfiguration" => [managed_output.fetch(:managed)],
      "ServiceDependency" => [Valpo::API::V1::Services.render_dependency(dependency)],
      "Release" => [release_output],
      "ReleaseBuild" => [release_output.fetch(:build)],
      "Domain" => [Valpo::API::V1::Services.render_domain(domain)],
      "PlatformDomain" => [Valpo::API::V1::System.render_domain(platform_domain)],
      "Job" => [Valpo::API::V1::Jobs.render(job)],
      "JobEvent" => [Valpo::API::V1::Jobs.render_event(event)],
      "ServiceLogs" => [{stdout: "ready\n", stderr: "", service: app_output}],
      "ProjectLogEntry" => [successful_log, failed_log],
      "ProjectLogs" => [{project: project_output, logs: [successful_log, failed_log]}],
      "APICredential" => [Valpo::API::V1::APICredentials.render(api_credential)],
      "ServiceEnvironmentVariable" => [Valpo::API::V1::Services.render_environment_variable(environment_variable)],
      "EnvironmentEntry" => [environment_entry],
      "ServiceEnvironment" => [{service: app_output, env: [environment_entry]}]
    }
  end

  def route_comments
    route_files.flat_map do
      File.readlines(it).filter_map do
        match = it.match(/# (GET|POST|PUT|PATCH|DELETE) (\/\S*) —/)
        "#{match[1]} #{match[2]}" if match
      end
    end
  end

  def route_files
    @route_files ||= [
      File.join(Valpo.root, "lib", "valpo", "api", "app.rb"),
      *Dir[File.join(Valpo.root, "lib", "valpo", "api", "routes", "*.rb")]
    ].sort
  end

  def relative_path(path)
    path.delete_prefix("#{Valpo.root}/")
  end

  def collect_references(value)
    case value
    when Hash
      value.flat_map do |key, child|
        (key == "$ref") ? [child] : collect_references(child)
      end
    when Array
      value.flat_map { collect_references(it) }
    else
      []
    end
  end

  def resolve_reference(reference)
    assert reference.start_with?("#/"), "External reference is not allowed: #{reference}"
    reference.delete_prefix("#/").split("/").reduce(spec) do |value, component|
      key = component.gsub("~1", "/").gsub("~0", "~")
      assert value.is_a?(Hash) && value.key?(key), "Unresolved reference: #{reference}"
      value.fetch(key)
    end
  end
end
