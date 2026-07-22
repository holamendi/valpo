# frozen_string_literal: true

require "test_helper"

class ValpoDomainsReachabilityVerifierTest < Minitest::Test
  def test_accepts_only_matching_https_challenge
    requests = []
    verifier = Valpo::Domains::ReachabilityVerifier.new(
      requester: lambda do |url|
        requests << url
        {status: 200, body: "token-123\n"}
      end
    )

    assert verifier.verify!(hostname: "web.example.com", token: "token-123")
    assert_equal "https://web.example.com/.well-known/valpo-verification/token-123", requests.first
  end

  def test_reports_unreachable_challenge
    verifier = Valpo::Domains::ReachabilityVerifier.new(
      requester: ->(_url) { raise Errno::ECONNREFUSED },
      clock: -> { 0 },
      timeout: 0
    )

    error = assert_raises Valpo::ValidationError do
      verifier.verify!(hostname: "web.example.com", token: "token-123")
    end
    assert_match "Domain verification failed", error.message
  end
end
