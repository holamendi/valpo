# frozen_string_literal: true

require "sequel/model"
require "securerandom"
require "time"

module Valpo
  class PlatformDomain < Sequel::Model(:platform_domains)
    include Valpo::LifecycleTransitions

    STATUSES = %w[pending verified failed].freeze
    TRANSITIONS = {
      "pending" => %w[verified failed],
      "verified" => %w[pending failed],
      "failed" => %w[pending verified]
    }.freeze

    one_to_many :domains

    def before_validation
      self.hostname = Valpo::Hostname.normalize(hostname) if hostname
      self.status ||= "pending"
      self.active = false if active.nil?
      self.verification_token ||= SecureRandom.hex(24)
      super
    end

    def before_create
      timestamp = Time.now.utc
      self.id ||= Valpo::Identifier.generate(:platform_domain)
      self.created_at ||= timestamp
      self.updated_at ||= timestamp
      super
    end

    def before_update
      self.updated_at = Time.now.utc
      super
    end

    def validate
      super
      errors.add(:hostname, "is required") if hostname.nil? || hostname.empty?
      errors.add(:hostname, "must be a valid hostname") if hostname && !Valpo::Hostname.valid?(hostname)
      errors.add(:status, "must be one of: #{STATUSES.join(", ")}") unless STATUSES.include?(status)
      errors.add(:active, "requires verified status") if active && status != "verified"
    end

    def activate!(verified_at: Time.now.utc)
      db.transaction do
        self.class.exclude(id:).where(active: true).update(active: false)
        transition_to!("verified", active: true, verification_error: nil, verified_at:)
      end
      refresh
    end

    def verification_hostname
      "valpo-#{verification_token[0, 24]}.#{hostname}"
    end

    def verified?
      status == "verified"
    end
  end
end
