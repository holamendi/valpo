# frozen_string_literal: true

class Valpo::API::Client::Error < StandardError
  def initialize(message, retryable: false)
    super(message)
    @retryable = retryable
  end

  def retryable?
    @retryable
  end
end
