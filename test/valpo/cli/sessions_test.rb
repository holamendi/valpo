# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "test_helper"

class ValpoCLISessionsTest < Minitest::Test
  TOKEN = "valpo_test_token"
  CREDENTIAL = {"id" => "acr_01900000000070008000000000000000", "name" => "mac", "scopes" => ["admin"]}.freeze

  def setup
    super
    @directory = Dir.mktmpdir("valpo-login")
    @path = File.join(@directory, "profiles", "cli.json")
    @profiles = Valpo::CLI::Profiles.new(path: @path)
    @requests = []
    @response = CREDENTIAL
    @environment = {}
    @sessions = Valpo::CLI::Sessions.new(
      profiles: @profiles,
      environment: @environment,
      client_factory: lambda do |url, token|
        client = Object.new
        client.define_singleton_method(:request) do |method, path, *_args|
          @request_handler.call(url, token, method, path)
        end
        client.instance_variable_set(:@request_handler, lambda do |*request|
          @requests << request
          raise @response if @response.is_a?(Exception)

          @response
        end)
        client
      end
    )
  end

  def teardown
    FileUtils.remove_entry(@directory)
    super
  end

  def test_login_validates_then_saves_private_profile_without_echoing_token
    status, out, err = cli(%w[login --server https://VALPO.test/ --name live --with-token --json], "#{TOKEN}\n")

    assert_equal 0, status, err
    assert_empty err
    assert_equal "live", JSON.parse(out).fetch("server")
    refute_includes out, TOKEN
    assert_equal [["https://valpo.test", TOKEN, :get, "/v1/session"]], @requests
    saved = JSON.parse(File.read(@path))
    assert_equal "live", saved.fetch("current")
    assert_equal TOKEN, saved.dig("servers", "live", "token")
    assert_equal 0o600, File.stat(@path).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(@path)).mode & 0o777

    @sessions.client.request(:get, "/health")
    assert_equal ["https://valpo.test", TOKEN, :get, "/health"], @requests.last
  end

  def test_failed_login_preserves_previous_token_and_default
    login
    before = File.binread(@path)
    @response = Valpo::API::Client::Error.new("401: Unauthorized")

    status, out, err = cli(%w[login --server https://valpo.test --name live --with-token], "valpo_rejected\n")
    assert_equal 1, status
    assert_empty out
    assert_includes err, "401"
    assert_equal before, File.binread(@path)
  end

  def test_failed_first_login_does_not_create_a_config
    @response = Valpo::API::Client::Error.new("API request failed")
    assert_raises(Valpo::API::Client::Error) { login }
    refute File.exist?(@path)
  end

  def test_explicit_url_never_inherits_saved_credentials
    login
    @sessions.client(api_url: "https://other.test").request(:get, "/health")
    assert_equal ["https://other.test", nil, :get, "/health"], @requests.last

    @environment["VALPO_API_URL"] = "https://env.test"
    @sessions.client.request(:get, "/health")
    assert_equal ["https://env.test", nil, :get, "/health"], @requests.last

    @environment["VALPO_API_TOKEN"] = "valpo_environment"
    @sessions.client.request(:get, "/health")
    assert_equal ["https://env.test", "valpo_environment", :get, "/health"], @requests.last
    @sessions.client(server: "live").request(:get, "/health")
    assert_equal ["https://valpo.test", "valpo_environment", :get, "/health"], @requests.last
  end

  def test_profile_switching_and_global_server_option
    login
    @sessions.login(name: "other", url: "https://other.test", token: "valpo_other")
    assert_equal 0, cli(%w[server use live]).first
    status, out, = cli(%w[server list --json])
    assert_equal 0, status
    assert_equal ["live"], JSON.parse(out).select { it.fetch("current") }.map { it.fetch("name") }
    refute_includes out, TOKEN
    refute_includes out, "valpo_other"

    @response = []
    assert_equal 0, cli(%w[--server other project list]).first
    assert_equal ["https://other.test", "valpo_other", :get, "/v1/projects"], @requests.last
    assert_equal 0, cli(%w[project list --server live]).first
    assert_equal ["https://valpo.test", TOKEN, :get, "/v1/projects"], @requests.last
  end

  def test_logout_is_local_and_does_not_select_another_server
    login
    @sessions.login(name: "other", url: "https://other.test", token: "valpo_other")
    @requests.clear
    @sessions.logout
    assert_empty @requests
    assert_nil @profiles.read["current"]
    assert_equal ["live"], @profiles.read["servers"].keys
    refute_includes File.read(@path), "valpo_other"
  end

  def test_revocation_uses_saved_token_and_preserves_login_on_failure
    login
    @environment["VALPO_API_TOKEN"] = "valpo_someone_else"
    @response = Valpo::API::Client::Error.new("409: Cannot revoke the final active admin")
    assert_raises(Valpo::API::Client::Error) { @sessions.logout(revoke: true) }
    assert_equal TOKEN, @profiles.read.dig("servers", "live", "token")
    assert_equal ["https://valpo.test", TOKEN, :delete, "/v1/session"], @requests.last
    @response = {"revoked" => true}
    assert_equal 0, cli(%w[logout --server live --revoke]).first
    assert_empty @profiles.read["servers"]
  end

  def test_rejects_insecure_urls_and_ambiguous_selection
    ["http://remote.test", "https://user:secret@valpo.test", "https://valpo.test?token=secret", "https://valpo.test/../x"].each do |url|
      assert_raises(Valpo::CLI::UsageError) { @sessions.login(name: "live", url:, token: TOKEN) }
    end
    assert_empty @requests
    assert_raises(Valpo::CLI::UsageError) { @sessions.client(server: "live", api_url: "https://valpo.test") }
    assert_raises(Valpo::CLI::UsageError) { @sessions.client(server: "missing") }
    assert_equal "http://127.0.0.1:7092", Valpo::CLI::ServerAddress.normalize("http://127.0.0.1:7092/")
  end

  def test_login_does_not_silently_retarget_an_existing_name
    login
    assert_raises(Valpo::CLI::UsageError) { @sessions.login(name: "live", url: "https://other.test", token: TOKEN) }
    assert_equal "https://valpo.test", @profiles.read.dig("servers", "live", "api_url")
  end

  def test_rejects_insecure_corrupt_and_symlink_configs
    login
    File.chmod(0o644, @path)
    assert_raises(Valpo::CLI::OperationalError) { @profiles.read }
    File.chmod(0o600, @path)
    File.write(@path, "not json #{TOKEN}")
    error = assert_raises(Valpo::CLI::OperationalError) { @profiles.read }
    refute_includes error.message, TOKEN
    File.unlink(@path)
    target = File.join(@directory, "target")
    File.write(target, "protected")
    File.symlink(target, @path)
    assert_raises(Valpo::CLI::OperationalError) { login }
    assert_equal "protected", File.read(target)
  end

  def test_failed_config_update_is_atomic
    login
    before = File.binread(@path)
    assert_raises(RuntimeError) do
      @profiles.update do
        it["servers"].clear
        raise "simulated failure"
      end
    end
    assert_equal before, File.binread(@path)
  end

  def test_piped_input_requires_explicit_flag_and_secret_arguments_are_not_echoed
    status, out, err = cli(%w[login --server https://valpo.test], "#{TOKEN}\n")
    assert_equal 2, status
    assert_empty out
    assert_includes err, "--with-token"
    status, out, err = cli(["login", "--server", "https://valpo.test", TOKEN])
    assert_equal 2, status
    refute_includes out + err, TOKEN
    assert_empty @requests
  end

  def test_interactive_input_is_hidden
    input = StringIO.new("#{TOKEN}\n")
    hidden = false
    input.define_singleton_method(:tty?) { true }
    input.define_singleton_method(:noecho) do |&block|
      hidden = true
      block.call(self)
    end
    status, out, err = cli(%w[login --server https://valpo.test --name live], input)
    assert_equal 0, status, err
    assert hidden
    assert_includes err, "API token:"
    refute_includes out + err, TOKEN
  end

  private

  def login
    @sessions.login(name: "live", url: "https://valpo.test", token: TOKEN)
  end

  def cli(arguments, input = "")
    out = StringIO.new
    err = StringIO.new
    input = StringIO.new(input) if input.is_a?(String)
    status = Valpo::CLI.call(arguments, out:, err:, input:, sessions: @sessions)
    [status, out.string, err.string]
  end
end
