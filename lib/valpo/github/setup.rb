# frozen_string_literal: true

require "digest"
require "securerandom"
require "time"
require "uri"

module Valpo
  module GitHub
    class Setup
      INTEGRATION_PREFIX = "/integrations/github"
      SETUP_TTL = 3600
      ORGANIZATION_PATTERN = /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\z/

      def initialize(
        credentials: nil,
        personal_access_token: nil,
        validator: nil,
        client: nil,
        clock: -> { Time.now.utc }
      )
        @credentials = credentials || Credentials.new
        @personal_access_token = personal_access_token || PersonalAccessToken.new
        @validator = validator || Valpo::Sources::GitHub::Validator.new
        @client = client || Client.new(credentials: @credentials)
        @clock = clock
      end

      def start(organization: nil)
        raise Valpo::ConflictError, "GitHub App authentication is already configured" if credentials.configured?

        domain = Valpo::Domains::Configuration.active
        unless domain
          raise Valpo::ValidationError, "Configure and verify the default app domain before connecting GitHub"
        end
        organization = normalized_organization(organization)

        token = SecureRandom.urlsafe_base64(32, padding: false)
        now = clock.call
        Valpo::GitHubAppSetup.where(status: "pending").where { expires_at <= now }.delete
        Valpo::GitHubAppSetup.create(
          state_digest: digest(token),
          app_domain: domain.hostname,
          organization:,
          expires_at: now + SETUP_TTL
        )
        {
          "expires_at" => (now + SETUP_TTL).iso8601,
          "setup_url" => "#{base_url(domain.hostname)}/setup?token=#{URI.encode_www_form_component(token)}"
        }
      end

      def form(token)
        setup = find_pending!(token)
        {
          manifest: Manifest.build(base_url(setup.app_domain)),
          organization: setup.organization
        }
      end

      def complete(code:, state:)
        raise Valpo::ConflictError, "GitHub App authentication is already configured" if credentials.configured?
        setup = find_pending!(state)
        values = client.convert_manifest(required(code, "GitHub manifest code"))
        values["app_domain"] = setup.app_domain
        credentials.write(values)
        setup.update(status: "completed")
        values.slice("app_id", "client_id", "owner", "slug").merge(
          "install_url" => "https://github.com/apps/#{values.fetch("slug")}/installations/new"
        )
      end

      def installation(installation_id)
        values = client.installation(installation_id)
        {
          "account" => values.dig("account", "login"),
          "installation_id" => values.fetch("id"),
          "repository_selection" => values.fetch("repository_selection")
        }
      rescue KeyError
        raise Valpo::ValidationError, "GitHub returned an invalid App installation"
      end

      def status
        values = credentials.public_values
        return {"authenticated" => true, "provider" => "github", "mode" => "app"}.merge(values) if values

        pat_values = personal_access_token.public_values
        return {"authenticated" => true, "provider" => "github", "mode" => "pat"}.merge(pat_values) if pat_values

        {"authenticated" => false, "provider" => "github"}
      end

      def login_with_token(token)
        account = validator.validate(token)
        personal_access_token.write(token, account:)
        {"authenticated" => true, "provider" => "github", "mode" => "pat", "account" => account}
      end

      def logout
        credentials.delete | personal_access_token.delete
      end

      def self.hostname(app_domain)
        "github.#{app_domain}"
      end

      def self.pending?(at: Time.now.utc)
        Valpo::GitHubAppSetup.where(status: "pending").where { expires_at > at }.count.positive?
      end

      private

      attr_reader :credentials, :personal_access_token, :validator, :client, :clock

      def base_url(app_domain)
        "https://#{self.class.hostname(app_domain)}#{INTEGRATION_PREFIX}"
      end

      def find_pending!(token)
        value = required(token, "GitHub setup state")
        setup = Valpo::GitHubAppSetup.where(state_digest: digest(value)).first
        unless setup&.pending?(at: clock.call)
          raise Valpo::ValidationError, "GitHub App setup link is invalid or expired"
        end

        setup
      end

      def required(value, name)
        text = value.to_s
        raise Valpo::ValidationError, "#{name} is required" if text.empty?

        text
      end

      def normalized_organization(value)
        return nil if value.nil? || value.to_s.empty?

        organization = value.to_s
        unless organization.match?(ORGANIZATION_PATTERN)
          raise Valpo::ValidationError, "GitHub organization must contain only letters, numbers, and hyphens"
        end

        organization
      end

      def digest(value)
        Digest::SHA256.hexdigest(value)
      end
    end
  end
end
