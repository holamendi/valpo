# frozen_string_literal: true

require "test_helper"
require "yaml"

class ValpoAPIOpenAPITest < Minitest::Test
  HTTP_METHODS = %w[get post put patch delete].freeze
  SPEC_PATH = File.join(Valpo.root, "docs", "openapi.yaml")

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

  def test_create_service_schema_mirrors_contract_keys_and_strict_nested_shapes
    schema = spec.dig("components", "schemas", "CreateServiceRequest")
    contract = Valpo::API::V1::Services::CreateContract.new
    contract_keys = contract.schema.key_map.map(&:name)
    assert_equal contract_keys.sort, schema.fetch("properties").keys.sort
    assert_equal %w[name type], schema.fetch("required")
    assert_equal false, schema.fetch("additionalProperties")
    refute_includes schema.fetch("properties"), "port"

    source_key = contract.schema.key_map.find { it.name == "source" }
    source_schema = spec.dig("components", "schemas", "SourceInput")
    assert_equal source_key.members.map(&:name).sort, source_schema.fetch("properties").keys.sort
    assert_equal false, source_schema.fetch("additionalProperties")
    assert_equal 65_535, spec.dig("components", "schemas", "Port", "maximum")
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
