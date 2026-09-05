# frozen_string_literal: true

require "sequel/model"

module Valpo
  class ControlPlaneState < Sequel::Model(:control_plane_states)
    SINGLETON_ID = 1

    def self.current
      self[SINGLETON_ID] || raise(Valpo::ValidationError, "Control-plane state is missing; restore or migrate the database")
    end

    def self.api_bootstrapped?
      !current.api_bootstrapped_at.nil?
    end

    def mark_api_bootstrapped!(at: Time.now.utc)
      return self if api_bootstrapped_at

      update(api_bootstrapped_at: at, updated_at: at)
    end

    def validate
      super
      errors.add(:id, "must identify the singleton control-plane state") unless id == SINGLETON_ID
    end
  end
end
