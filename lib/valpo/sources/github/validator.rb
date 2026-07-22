# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

class Valpo::Sources::GitHub::Validator
  API_VERSION = "2026-03-10"
  ENDPOINT = URI("https://api.github.com/user")

  def initialize(requester: Requester.new)
    @requester = requester
  end

  def validate(token)
    response = requester.get(
      ENDPOINT,
      "Accept" => "application/vnd.github+json",
      "Authorization" => "Bearer #{token}",
      "User-Agent" => "valpo/#{Valpo::VERSION}",
      "X-GitHub-Api-Version" => API_VERSION
    )
    case response.fetch(:status)
    when 200
      login = JSON.parse(response.fetch(:body)).fetch("login").to_s
      raise Valpo::ValidationError, "GitHub returned an invalid authenticated-user response" if login.empty?

      login
    when 401
      raise Valpo::ValidationError, "GitHub rejected the PAT"
    when 403
      raise Valpo::ValidationError, "GitHub temporarily refused PAT validation"
    else
      raise Valpo::ValidationError, "GitHub PAT validation failed with HTTP #{response.fetch(:status)}"
    end
  rescue Valpo::ValidationError
    raise
  rescue JSON::ParserError, KeyError
    raise Valpo::ValidationError, "GitHub returned an invalid authenticated-user response"
  rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => e
    raise Valpo::ValidationError, "Could not validate GitHub PAT: #{e.message}"
  end

  private

  attr_reader :requester
end
