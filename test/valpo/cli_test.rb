# frozen_string_literal: true

require "test_helper"
require "valpo/cli"

class ValpoCLITest < Minitest::Test
  def test_cli_exits_nonzero_on_failures
    assert_equal true, Valpo::CLI.exit_on_failure?
  end

  def test_requests_use_api_client
    config_path = File.join(VALPO_TEST_DIR, "cli-token.yml")
    client = FakeAPIClient.new([])
    client_options = nil

    Valpo::API::Client.stub(:new, ->(**options) {
      client_options = options
      client
    }) do
      capture_io { Valpo::CLI.start(["projects:list", "--config", config_path]) }
    end

    assert_equal "/projects", client.requests.first.fetch(:path)
    assert_equal config_path, client_options.fetch(:config_path)
  end

  def test_client_errors_are_thor_errors
    client = FakeAPIClient.new(Valpo::API::Client::Error.new("connection refused"))
    cli = Valpo::CLI.new

    Valpo::API::Client.stub(:new, client) do
      error = assert_raises(Thor::Error) do
        cli.send(:request, :get, "/projects")
      end

      assert_equal "connection refused", error.message
    end
  end

  private

  class FakeAPIClient
    attr_reader :requests

    def initialize(response)
      @response = response
      @requests = []
    end

    def request(method, path, payload = nil)
      requests << {method: method, path: path, payload: payload}
      raise response if response.is_a?(StandardError)

      response
    end

    private

    attr_reader :response
  end
end
