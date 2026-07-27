# frozen_string_literal: true

require "digest"
require "json"
require "openssl"
require "rack/utils"

module Valpo
  module GitHub
    class Webhook
      SIGNATURE_PREFIX = "sha256="

      def initialize(
        config: Valpo.config || Valpo::Config.load,
        credentials: nil,
        queue: Valpo::Jobs::Queue.new
      )
        @credentials = credentials || Credentials.new
        @queue = queue
      end

      def valid_signature?(body, signature)
        secret = credentials.read&.fetch("webhook_secret")
        return false unless secret

        expected = "#{SIGNATURE_PREFIX}#{OpenSSL::HMAC.hexdigest("SHA256", secret, body)}"
        provided = signature.to_s
        provided.bytesize == expected.bytesize && Rack::Utils.secure_compare(provided, expected)
      end

      def receive(event:, delivery_id:, body:)
        payload = JSON.parse(body)
        Valpo::Database.connection.transaction(mode: :immediate) do
          delivery = record_delivery(event:, delivery_id:, body:)
          next({"duplicate" => true, "jobs" => []}) unless delivery

          jobs = (event == "push") ? enqueue_push(payload) : []
          delivery.update(jobs_count: jobs.length)
          {"duplicate" => false, "jobs" => jobs.map(&:id)}
        end
      rescue JSON::ParserError
        raise Valpo::ValidationError, "GitHub webhook payload must be valid JSON"
      end

      private

      attr_reader :credentials, :queue

      def record_delivery(event:, delivery_id:, body:)
        raise Valpo::ValidationError, "GitHub delivery ID is required" if delivery_id.to_s.empty?
        raise Valpo::ValidationError, "GitHub event is required" if event.to_s.empty?

        Valpo::GitHubWebhookDelivery.create(
          id: delivery_id,
          event:,
          payload_digest: Digest::SHA256.hexdigest(body)
        )
      rescue Sequel::UniqueConstraintViolation
        nil
      end

      def enqueue_push(payload)
        repository = payload.dig("repository", "full_name").to_s
        ref = payload.fetch("ref", "").to_s
        commit = payload.fetch("after", "").to_s
        default_ref = "refs/heads/#{payload.dig("repository", "default_branch")}"
        return [] unless repository.match?(Valpo::Sources::GitHub::REPOSITORY_PATTERN)
        return [] unless commit.match?(Valpo::Sources::Preflight::COMMIT_PATTERN)
        return [] if payload["deleted"] || commit.match?(/\A0+\z/)

        Valpo::Source.where(provider: "github", repository:, auto_deploy: true).order(:created_at).flat_map do |source|
          matches_ref = ref == "refs/heads/#{source.ref}" || (source.ref == "HEAD" && ref == default_ref)
          next [] unless matches_ref

          services_for(source).filter_map do
            queue.enqueue_service_operation(
              "deploy_source",
              service_id: it.id,
              payload: {project_id: it.project_id, ref: commit}
            )
          rescue Valpo::ConflictError
            nil
          end
        end
      end

      def services_for(source)
        build_ids = Valpo::BuildTarget.where(source_id: source.id).select_map(:id)
        return [] if build_ids.empty?

        service_ids = Valpo::AppServiceConfig.where(build_target_id: build_ids).select_map(:service_id)
        Valpo::Service.where(id: service_ids).order(:created_at).all
      end
    end
  end
end
