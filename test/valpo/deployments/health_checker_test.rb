# frozen_string_literal: true

require "test_helper"

class ValpoDeploymentsHealthCheckerTest < Minitest::Test
  def test_default_readiness_requires_an_http_response
    checker = Valpo::Deployments::HealthChecker.new(http: FakeHTTP.new(error: EOFError.new))

    error = assert_raises(Valpo::ValidationError) do
      checker.wait(route_target: "127.0.0.1:3000", path: nil, timeout: 0)
    end

    assert_match "Health check failed", error.message
  end

  def test_default_readiness_accepts_any_http_status
    checker = Valpo::Deployments::HealthChecker.new(http: FakeHTTP.new(status: 404))

    assert checker.wait(route_target: "127.0.0.1:3000", path: nil, timeout: 0)
  end

  def test_explicit_healthcheck_requires_a_success_or_redirect
    checker = Valpo::Deployments::HealthChecker.new(http: FakeHTTP.new(status: 404))

    assert_raises(Valpo::ValidationError) do
      checker.wait(route_target: "127.0.0.1:3000", path: "/health", timeout: 0)
    end
  end

  private

  class FakeHTTP
    Response = Data.define(:code)

    def initialize(status: nil, error: nil)
      @status = status
      @error = error
    end

    def start(*, **)
      raise @error if @error

      yield Session.new(@status)
    end

    Session = Data.define(:status) do
      def get(_path)
        Response.new(status.to_s)
      end
    end
  end
end
