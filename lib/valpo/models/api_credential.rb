# frozen_string_literal: true

require "digest"
require "json"
require "rack/utils"
require "securerandom"
require "sequel/model"
require "time"

module Valpo
  class APICredential < Sequel::Model(:api_credentials)
    SCOPES = %w[admin read write].freeze
    TOKEN_PREFIX = "valpo_"

    def self.issue(name:, scopes: ["admin"], expires_at: nil)
      Valpo::Database.connection.transaction(mode: :immediate) do
        credential, token = create_credential(name:, scopes:, expires_at:)
        Valpo::ControlPlaneState.current.mark_api_bootstrapped!
        [credential, token]
      end
    end

    def self.bootstrap(name:, scopes: ["admin"])
      unless Array(scopes).map(&:to_s).include?("admin")
        raise Valpo::ValidationError, "Bootstrap credential must include the admin scope"
      end

      Valpo::Database.connection.transaction(mode: :immediate) do
        state = Valpo::ControlPlaneState.current
        raise Valpo::ConflictError, "API bootstrap has already completed" if state.api_bootstrapped_at

        credential, token = create_credential(name:, scopes:)
        state.mark_api_bootstrapped!
        [credential, token]
      end
    end

    def self.recover(name:)
      Valpo::Database.connection.transaction(mode: :immediate) do
        if active.all.any?(&:admin?)
          raise Valpo::ConflictError, "An active admin API credential already exists"
        end

        credential, token = create_credential(name:, scopes: ["admin"])
        Valpo::ControlPlaneState.current.mark_api_bootstrapped!
        [credential, token]
      end
    end

    def self.create_credential(name:, scopes:, expires_at: nil)
      token = "#{TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(32, padding: false)}"
      credential = create(
        name:,
        token_prefix: token[0, 16],
        token_digest: digest(token),
        scopes_json: JSON.generate(Array(scopes).uniq.sort),
        expires_at:
      )
      [credential, token]
    end
    private_class_method :create_credential

    def self.authenticate(token, at: Time.now.utc)
      value = token.to_s
      return nil if value.empty?

      candidate = where(token_prefix: value[0, 16], revoked_at: nil).all.find do
        next false if it.expires_at && it.expires_at <= at

        provided = digest(value)
        provided.bytesize == it.token_digest.bytesize &&
          Rack::Utils.secure_compare(provided, it.token_digest)
      end
      candidate&.update(last_used_at: at)
      candidate
    end

    def self.active
      where(revoked_at: nil).where { (expires_at =~ nil) | (expires_at > Time.now.utc) }
    end

    def self.digest(token)
      Digest::SHA256.hexdigest(token)
    end

    def scopes
      JSON.parse(scopes_json || "[]")
    end

    def allows?(method)
      return true if admin?

      method.to_s.upcase.match?(/\A(?:GET|HEAD)\z/) ? scopes.include?("read") : scopes.include?("write")
    end

    def admin?
      scopes.include?("admin")
    end

    def revoke!
      self.class.db.transaction(mode: :immediate) do
        refresh
        if active? && admin? && self.class.active.all.count(&:admin?) == 1
          raise Valpo::ConflictError, "Cannot revoke the final active admin API credential"
        end

        update(revoked_at: Time.now.utc)
      end
    end

    def active?(at: Time.now.utc)
      revoked_at.nil? && (expires_at.nil? || expires_at > at)
    end

    def before_create
      timestamp = Time.now.utc
      self.id ||= Valpo::Identifier.generate(:api_credential)
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
      errors.add(:name, "is required") if name.nil? || name.strip.empty?
      errors.add(:token_prefix, "is required") if token_prefix.nil? || token_prefix.empty?
      errors.add(:token_digest, "is invalid") unless token_digest.to_s.match?(/\A[0-9a-f]{64}\z/)
      errors.add(:scopes_json, "must contain valid scopes") unless scopes.is_a?(Array) && scopes.any? && (scopes - SCOPES).empty?
    rescue JSON::ParserError
      errors.add(:scopes_json, "must contain valid scopes")
    end
  end
end
