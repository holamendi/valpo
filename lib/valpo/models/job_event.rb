# frozen_string_literal: true

require "securerandom"
require "sequel/model"
require "time"

module Valpo
  class JobEvent < Sequel::Model(:job_events)
    def before_create
      self.id ||= SecureRandom.uuid
      self.created_at ||= Time.now.utc
      super
    end
  end
end
