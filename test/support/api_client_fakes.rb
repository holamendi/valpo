# frozen_string_literal: true

module ValpoTestSupport
  FakeHTTPResponse = Struct.new(:code, :body)

  class FakeHTTP
    attr_reader :last_request
    attr_accessor :use_ssl, :open_timeout, :read_timeout

    def initialize(response: nil, error: nil)
      @response = response
      @error = error
    end

    def request(request)
      @last_request = request
      raise error if error

      response
    end

    private

    attr_reader :response, :error
  end
end
