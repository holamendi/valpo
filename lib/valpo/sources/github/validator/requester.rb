# frozen_string_literal: true

require "net/http"

class Valpo::Sources::GitHub::Validator::Requester
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  def get(uri, headers)
    request = Net::HTTP::Get.new(uri.request_uri, headers)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT
    response = http.request(request)
    {status: response.code.to_i, body: response.body.to_s}
  end
end
