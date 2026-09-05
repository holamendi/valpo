# frozen_string_literal: true

require "json"

Sequel.migration do
  up do
    strategies = {
      "rotate_secrets" => "resumable", "deploy_registry_image" => "resumable",
      "deploy_source" => "resumable", "create_source_service" => "resumable",
      "update_app_service" => "resumable", "provision_service" => "resumable",
      "bind_service" => "resumable", "unbind_service" => "resumable",
      "restart_service" => "resumable", "reconcile_service_environment" => "resumable",
      "apply_project_manifest" => "resumable", "rollback_release" => "compensating",
      "delete_project" => "compensating", "delete_service" => "compensating"
    }.freeze
    alter_table(:jobs) do
      add_column :project_id, String, size: 40
      add_column :project_name, String
      add_column :service_id, String, size: 40
      add_column :related_service_id, String, size: 40
      add_column :idempotency_key, String
      add_column :attempt, Integer, null: false, default: 0
      add_column :operation_generation, Integer, null: false, default: 1
      add_column :recovery_strategy, String, null: false, default: "retryable"
      add_column :checkpoint, String
      add_column :recovery_action, String
      add_column :lease_expires_at, DateTime
    end

    generations = Hash.new(0)
    from(:jobs).order(:created_at, :id).each do
      payload = JSON.parse(it.fetch(:payload_json))
      project_id = payload["project_id"]
      service_id = payload["service_id"]
      related_service_id = payload["dependency_service_id"]

      if !project_id && (project_name = payload["project_name"] || payload.dig("manifest", "project", "name"))
        project_id = from(:projects).where(name: project_name).get(:id)
      end

      scope = if service_id
        [:service, service_id]
      elsif project_id
        [:project, project_id]
      else
        [:system, it.fetch(:type)]
      end
      generation = generations[scope] += 1

      from(:jobs).where(id: it.fetch(:id)).update(
        project_id:,
        project_name: payload["project_name"] || payload.dig("manifest", "project", "name"),
        service_id:,
        related_service_id:,
        recovery_strategy: strategies.fetch(it.fetch(:type), "retryable"),
        operation_generation: generation
      )
    end

    alter_table(:jobs) do
      add_constraint(:jobs_state_valid) do
        Sequel.&(
          {status: %w[queued running succeeded failed]},
          attempt >= 0,
          operation_generation > 0,
          {recovery_strategy: %w[retryable resumable compensating]}
        )
      end
      add_index :idempotency_key, unique: true, name: :jobs_idempotency_key_unique
      add_index [:project_id, :status, :created_at], name: :jobs_project_active_lookup
      add_index [:project_name, :status, :created_at], name: :jobs_project_name_active_lookup
      add_index [:service_id, :status, :created_at], name: :jobs_service_active_lookup
      add_index [:related_service_id, :status, :created_at], name: :jobs_related_service_active_lookup
      add_index [:project_id, :operation_generation], name: :jobs_project_generation
      add_index [:service_id, :operation_generation], name: :jobs_service_generation
      add_index :lease_expires_at
    end
  end

  down do
    alter_table(:jobs) do
      drop_index :lease_expires_at
      drop_index [:service_id, :operation_generation], name: :jobs_service_generation
      drop_index [:project_id, :operation_generation], name: :jobs_project_generation
      drop_index [:related_service_id, :status, :created_at], name: :jobs_related_service_active_lookup
      drop_index [:service_id, :status, :created_at], name: :jobs_service_active_lookup
      drop_index [:project_id, :status, :created_at], name: :jobs_project_active_lookup
      drop_index [:project_name, :status, :created_at], name: :jobs_project_name_active_lookup
      drop_index :idempotency_key, name: :jobs_idempotency_key_unique
      drop_constraint :jobs_state_valid
      drop_column :lease_expires_at
      drop_column :recovery_action
      drop_column :checkpoint
      drop_column :recovery_strategy
      drop_column :operation_generation
      drop_column :attempt
      drop_column :idempotency_key
      drop_column :related_service_id
      drop_column :service_id
      drop_column :project_id
      drop_column :project_name
    end
    alter_table(:jobs) do
      add_constraint(:jobs_status_valid, status: %w[queued running succeeded failed])
    end
  end
end
