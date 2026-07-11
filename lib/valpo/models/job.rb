# frozen_string_literal: true

require "json"
require "sequel/model"
require "time"
require "valpo/identifier"

module Valpo
  class Job < Sequel::Model(:jobs)
    def payload
      JSON.parse(payload_json || "{}")
    end

    def before_create
      self.id ||= Valpo::Identifier.generate(:job)
      self.status ||= "queued"
      self.progress ||= 0
      self.created_at ||= Time.now.utc
      super
    end
  end
end
