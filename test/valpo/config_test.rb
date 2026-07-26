# frozen_string_literal: true

require "tempfile"
require "test_helper"

class ValpoConfigTest < Minitest::Test
  CONFIG_VALUES = {
    env: "test",
    root: Valpo.root,
    database_path: File.join(VALPO_TEST_DIR, "config.sqlite3"),
    api_host: "127.0.0.1",
    api_port: 7092,
    caddy_config_path: File.join(VALPO_TEST_DIR, "Caddyfile.config"),
    docker_network: "valpo",
    worker_poll_interval: 1,
    app_port_start: 20_000,
    app_port_end: 20_100,
    healthcheck_timeout: 1,
    deploy_drain_delay: 0
  }.freeze

  def test_loads_api_token_from_config_file
    file = Tempfile.new("valpo-config")
    file.write(<<~YAML)
      test:
        database_path: tmp/test.sqlite3
        api_host: 127.0.0.1
        api_port: 7092
        api_token: secret-token
        caddy_config_path: tmp/Caddyfile
        docker_network: valpo
        worker_poll_interval: 2
        app_port_start: 20000
        app_port_end: 29999
        healthcheck_timeout: 30
        deploy_drain_delay: 0
    YAML
    file.close

    config = Valpo::Config.load(path: file.path, env: "test")

    assert_equal "secret-token", config.api_token
    assert_equal 1_800, config.build_timeout
    assert_equal Valpo::Config::DEFAULT_BUILDPACK_BUILDER, config.buildpack_builder
  ensure
    file&.unlink
  end

  def test_loads_buildpack_settings
    file = Tempfile.new("valpo-build-config")
    file.write(<<~YAML)
      test:
        build_timeout: 900
        buildpack_builder: example/builder@sha256:abc
    YAML
    file.close

    config = Valpo::Config.load(path: file.path, env: "test")

    assert_equal 900, config.build_timeout
    assert_equal "example/builder@sha256:abc", config.buildpack_builder
  ensure
    file&.unlink
  end

  def test_loads_flat_configuration
    file = write_config(<<~YAML)
      database_path: tmp/flat.sqlite3
      api_port: 7100
    YAML

    config = Valpo::Config.load(path: file.path, env: "test")

    assert_equal 7100, config.api_port
    assert_equal File.join(Valpo.root, "tmp", "flat.sqlite3"), config.database_path
  ensure
    file&.unlink
  end

  def test_canonical_key_list_loads_every_supported_setting
    values = {
      "database_path" => "tmp/full.sqlite3",
      "api_host" => "0.0.0.0",
      "api_port" => 7100,
      "api_token" => "token",
      "github_token_path" => "tmp/github-token",
      "github_app_credentials_path" => "tmp/github-app.json",
      "caddy_config_path" => "tmp/Caddyfile.full",
      "caddy_reload_config_path" => "/etc/caddy/Caddyfile",
      "docker_network" => "valpo-full",
      "worker_poll_interval" => 0.5,
      "app_port_start" => 21_000,
      "app_port_end" => 21_999,
      "healthcheck_timeout" => 31,
      "deploy_drain_delay" => 1.5,
      "build_timeout" => 901,
      "buildpack_builder" => "example/builder@sha256:abc"
    }
    file = write_config(YAML.dump(values))
    config = Valpo::Config.load(path: file.path, env: "test")

    assert_equal values.keys.sort, Valpo::Config::KEYS.sort
    values.each do |key, expected|
      expected = File.expand_path(expected, Valpo.root) if key.end_with?("_path") && !expected.start_with?("/")
      assert_equal expected, config.public_send(key), key
    end
  ensure
    file&.unlink
  end

  def test_rejects_missing_file_environment_typo_unknown_key_and_mixed_layout
    missing = assert_raises(Valpo::ValidationError) do
      Valpo::Config.load(path: File.join(VALPO_TEST_DIR, "missing.yml"), env: "test")
    end
    assert_match "does not exist", missing.message

    nested = write_config("production:\n  api_port: 7092\n")
    environment = assert_raises(Valpo::ValidationError) { Valpo::Config.load(path: nested.path, env: "prodution") }
    assert_match "environment is missing: prodution", environment.message

    unknown = write_config("api_prt: 7092\n")
    unknown_error = assert_raises(Valpo::ValidationError) { Valpo::Config.load(path: unknown.path, env: "test") }
    assert_match "Unknown configuration keys: api_prt", unknown_error.message

    mixed = write_config("api_port: 7092\nproduction:\n  api_port: 7093\n")
    mixed_error = assert_raises(Valpo::ValidationError) { Valpo::Config.load(path: mixed.path, env: "test") }
    assert_match "cannot mix settings with environments", mixed_error.message

    unknown_nested = write_config("test:\n  api_port: 7092\nproduction:\n  api_prt: 7093\n")
    nested_error = assert_raises(Valpo::ValidationError) do
      Valpo::Config.load(path: unknown_nested.path, env: "test")
    end
    assert_match "Unknown configuration keys: api_prt", nested_error.message
  ensure
    nested&.unlink
    unknown&.unlink
    mixed&.unlink
    unknown_nested&.unlink
  end

  def test_rejects_invalid_yaml_and_non_mapping_documents
    invalid = write_config("production: [")
    invalid_error = assert_raises(Valpo::ValidationError) { Valpo::Config.load(path: invalid.path, env: "production") }
    assert_match "Configuration file is invalid", invalid_error.message

    sequence = write_config("- production\n")
    mapping_error = assert_raises(Valpo::ValidationError) { Valpo::Config.load(path: sequence.path, env: "production") }
    assert_match "must contain a mapping", mapping_error.message
  ensure
    invalid&.unlink
    sequence&.unlink
  end

  def test_rejects_invalid_numeric_configuration
    {
      "api_port" => ["invalid", "must be an integer"],
      "api_token" => [false, "must be a string"],
      "app_port_start" => ["1.5", "must be an integer"],
      "worker_poll_interval" => ["never", "must be a number"],
      "healthcheck_timeout" => ["soon", "must be an integer"]
    }.each do |key, (value, message)|
      file = write_config("#{key}: #{value}\n")
      error = assert_raises(Valpo::ValidationError) { Valpo::Config.load(path: file.path, env: "test") }
      assert_match message, error.message
      file.unlink
    end
  end

  def test_validates_operational_ranges
    {
      api_port: 0,
      worker_poll_interval: 0,
      app_port_start: 0,
      app_port_end: 70_000,
      healthcheck_timeout: 0,
      deploy_drain_delay: -1,
      build_timeout: 0,
      docker_network: ""
    }.each do |key, value|
      assert_raises(Valpo::ValidationError, key.to_s) { Valpo::Config.new(**CONFIG_VALUES.merge(key => value)) }
    end

    error = assert_raises(Valpo::ValidationError) do
      Valpo::Config.new(**CONFIG_VALUES.merge(app_port_start: 30_000, app_port_end: 20_000))
    end
    assert_match "must not be greater", error.message
  end

  def test_environment_variables_override_yaml
    file = write_config("api_port: 7092\n")
    previous = ENV["VALPO_API_PORT"]
    ENV["VALPO_API_PORT"] = "7199"

    assert_equal 7199, Valpo::Config.load(path: file.path, env: "test").api_port
  ensure
    ENV["VALPO_API_PORT"] = previous
    file&.unlink
  end

  def test_loads_github_token_lazily_from_the_private_file
    path = File.join(VALPO_TEST_DIR, "config-token")
    config = Valpo::Config.new(**CONFIG_VALUES.merge(github_token_path: path))

    Valpo::Credentials::FileStore.new(path).write("first-token")
    assert_equal "first-token", config.github_token
    Valpo::Credentials::FileStore.new(path).write("second-token")
    assert_equal "second-token", config.github_token
  end

  def test_places_github_app_credentials_beside_the_database_by_default
    config = Valpo::Config.new(
      **CONFIG_VALUES.merge(
        database_path: File.join(VALPO_TEST_DIR, "state", "config.sqlite3"),
        caddy_config_path: File.join(VALPO_TEST_DIR, "Caddyfile.github-app")
      )
    )

    assert_equal File.join(VALPO_TEST_DIR, "state", "secrets", "github-app.json"), config.github_app_credentials_path
  end

  private

  def write_config(contents)
    Tempfile.new("valpo-config").tap do
      it.write(contents)
      it.close
    end
  end
end
