# frozen_string_literal: true

require "json"

module Valpo
  module Secrets
    class Manager
      Target = Data.define(:name, :model, :column, :aad, :json)

      def initialize(secrets: Valpo.secrets, database: Valpo::Database.connection)
        @secrets = secrets
        @database = database
      end

      def verify
        counts = verify_records
        report(counts, active_key_version: secrets.active_key_version)
      end

      def rotate
        database.transaction(mode: :immediate) do
          before = verify_records
          previous_key_version = secrets.active_key_version
          active_key_version = secrets.rotate_key!
          reencrypt_records
          after = verify_records
          unless after == before
            raise Valpo::ValidationError, "Encrypted record counts changed during host-key rotation"
          end

          report(after, previous_key_version:, active_key_version:)
        end
      end

      private

      attr_reader :secrets, :database

      def targets
        @targets ||= [
          Target.new(
            name: "managed_service_credentials",
            model: Valpo::ManagedServiceConfig,
            column: :credentials_ciphertext,
            aad: -> { "managed_service_config:#{it.service_id}:credentials" },
            json: true
          ),
          Target.new(
            name: "service_environment_variables",
            model: Valpo::ServiceEnvironmentVariable,
            column: :value_ciphertext,
            aad: -> { "service_environment_variable:#{it.id}:value" },
            json: false
          ),
          Target.new(
            name: "provider_credentials",
            model: Valpo::ProviderCredential,
            column: :encrypted_payload,
            aad: -> { "provider_credential:#{it.id}:payload" },
            json: true
          )
        ].freeze
      end

      def verify_records
        targets.to_h do |target|
          count = 0
          target.model.order(target.model.primary_key).each do
            plaintext = decrypt(it, target)
            JSON.parse(plaintext) if target.json
            count += 1
          rescue JSON::ParserError
            raise Valpo::ValidationError, "Encrypted #{target.name} record #{it.pk} does not contain valid JSON"
          end
          [target.name, count]
        end
      end

      def reencrypt_records
        targets.each do |target|
          target.model.order(target.model.primary_key).each do
            plaintext = decrypt(it, target)
            ciphertext = secrets.encrypt(plaintext, aad: target.aad.call(it))
            updated = target.model.where(target.model.primary_key => it.pk).update(target.column => ciphertext)
            unless updated == 1
              raise Valpo::ConflictError, "Encrypted #{target.name} record #{it.pk} changed during host-key rotation"
            end
          end
        end
      end

      def decrypt(record, target)
        secrets.decrypt(record[target.column], aad: target.aad.call(record))
      rescue Valpo::ValidationError => e
        raise Valpo::ValidationError, "Encrypted #{target.name} record #{record.pk} cannot be verified: #{e.message}"
      end

      def report(records, active_key_version:, previous_key_version: nil)
        {
          active_key_version:,
          previous_key_version:,
          records:,
          total: records.values.sum
        }.compact
      end
    end
  end
end
