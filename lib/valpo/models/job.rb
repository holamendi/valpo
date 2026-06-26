# frozen_string_literal: true

require "json"
require "securerandom"
require "sequel/model"
require "time"

module Valpo
  class Job < Sequel::Model(:jobs)
    def payload
      JSON.parse(payload_json || "{}")
    end

    def before_create
      self.id ||= SecureRandom.uuid
      self.status ||= "queued"
      self.progress ||= 0
      self.created_at ||= Time.now.utc
      super
    end
  end
end
