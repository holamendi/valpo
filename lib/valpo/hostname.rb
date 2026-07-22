# frozen_string_literal: true

module Valpo
  module Hostname
    LABEL_PATTERN = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
    PATTERN = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

    module_function

    def normalize(value)
      value.to_s.strip.downcase.delete_suffix(".")
    end

    def valid?(value)
      value.to_s.match?(PATTERN)
    end
  end
end
