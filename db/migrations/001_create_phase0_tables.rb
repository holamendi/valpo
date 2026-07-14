# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:projects) do
      String :id, size: 40, primary_key: true
      String :name, null: false
      String :manifest_digest
      DateTime :last_applied_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :name, unique: true
    end

    create_table(:services) do
      String :id, size: 40, primary_key: true
      foreign_key :project_id, :projects, type: String, size: 40, null: false, on_delete: :restrict
      String :name, null: false
      String :kind, null: false
      String :status, null: false, default: "created"
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index [:project_id, :name], unique: true
      index [:project_id, :kind]
      index [:kind, :status]
    end

    create_table(:sources) do
      String :id, size: 40, primary_key: true
      foreign_key :project_id, :projects, type: String, size: 40, null: false, on_delete: :cascade
      foreign_key :owner_service_id, :services, type: String, size: 40, on_delete: :cascade
      String :name, null: false
      String :provider, null: false
      String :repository, null: false
      String :ref, null: false, default: "HEAD"
      TrueClass :auto_deploy, null: false, default: false
      String :status, null: false, default: "unconnected"
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index [:project_id, :name], unique: true
      index :owner_service_id, unique: true
    end

    create_table(:build_targets) do
      String :id, size: 40, primary_key: true
      foreign_key :project_id, :projects, type: String, size: 40, null: false, on_delete: :cascade
      foreign_key :source_id, :sources, type: String, size: 40, null: false, on_delete: :cascade
      foreign_key :owner_service_id, :services, type: String, size: 40, on_delete: :cascade
      String :name, null: false
      String :dockerfile, null: false, default: "Dockerfile"
      String :context, null: false, default: "."
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index [:project_id, :name], unique: true
      index :owner_service_id, unique: true
    end

    create_table(:app_service_configs) do
      foreign_key :service_id, :services, type: String, size: 40, primary_key: true, on_delete: :cascade
      foreign_key :build_target_id, :build_targets, type: String, size: 40, on_delete: :set_null
      String :command_json, text: true, null: false, default: "[]"
      Integer :internal_port
      String :healthcheck_path
    end

    create_table(:managed_service_configs) do
      foreign_key :service_id, :services, type: String, size: 40, primary_key: true, on_delete: :cascade
      String :version, null: false
      String :image, null: false
      String :plan, null: false, default: "starter"
      String :container_name
      String :volume_name
      String :internal_host
      Integer :internal_port
      String :credentials_json, text: true, null: false

      index :container_name
    end

    create_table(:service_dependencies) do
      String :id, size: 40, primary_key: true
      foreign_key :service_id, :services, type: String, size: 40, null: false, on_delete: :cascade
      foreign_key :dependency_service_id, :services, type: String, size: 40, null: false, on_delete: :restrict
      String :status, null: false, default: "binding"
      String :env_json, text: true, null: false, default: "{}"
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index [:service_id, :dependency_service_id], unique: true
      index [:service_id, :status]
    end

    create_table(:releases) do
      String :id, size: 40, primary_key: true
      foreign_key :service_id, :services, type: String, size: 40, null: false, on_delete: :cascade
      foreign_key :build_target_id, :build_targets, type: String, size: 40, on_delete: :set_null
      Integer :version, null: false
      String :source_type, null: false
      String :source_ref
      String :artifact_ref
      String :image_digest
      String :status, null: false, default: "pending"
      Integer :internal_port
      String :healthcheck_path
      String :container_name
      String :route_target
      DateTime :activated_at
      DateTime :created_at, null: false

      index [:service_id, :version], unique: true
      index [:service_id, :status]
      index :container_name
    end

    create_table(:domains) do
      String :id, size: 40, primary_key: true
      foreign_key :service_id, :services, type: String, size: 40, null: false, on_delete: :cascade
      String :hostname, null: false
      String :route_target
      String :tls_status, null: false, default: "unknown"
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :hostname, unique: true
      index :service_id
    end

    create_table(:jobs) do
      String :id, size: 40, primary_key: true
      String :type, null: false
      String :status, null: false
      String :payload_json, text: true, null: false
      Integer :progress, null: false, default: 0
      String :error, text: true
      String :locked_by
      DateTime :locked_at
      DateTime :started_at
      DateTime :finished_at
      DateTime :created_at, null: false

      index [:status, :created_at]
      index :locked_at
    end

    create_table(:job_events) do
      String :id, size: 40, primary_key: true
      foreign_key :job_id, :jobs, type: String, size: 40, null: false, on_delete: :cascade
      String :stream, null: false
      String :message, text: true, null: false
      DateTime :created_at, null: false

      index [:job_id, :created_at]
    end
  end
end
