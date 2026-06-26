# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:projects) do
      String :id, size: 36, primary_key: true
      String :name, null: false
      String :type, null: false, default: "container"
      String :status, null: false, default: "created"
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :name, unique: true
    end

    create_table(:releases) do
      String :id, size: 36, primary_key: true
      foreign_key :project_id, :projects, type: String, size: 36, null: false, on_delete: :cascade
      Integer :version, null: false
      String :source_type, null: false
      String :source_ref
      String :artifact_ref
      String :image_digest
      String :status, null: false, default: "pending"
      DateTime :activated_at
      DateTime :created_at, null: false

      index [:project_id, :version], unique: true
      index [:project_id, :status]
    end

    create_table(:domains) do
      String :id, size: 36, primary_key: true
      foreign_key :project_id, :projects, type: String, size: 36, null: false, on_delete: :cascade
      String :hostname, null: false
      String :route_target
      String :tls_status, null: false, default: "unknown"
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :hostname, unique: true
      index :project_id
    end

    create_table(:jobs) do
      String :id, size: 36, primary_key: true
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
      String :id, size: 36, primary_key: true
      foreign_key :job_id, :jobs, type: String, size: 36, null: false, on_delete: :cascade
      String :stream, null: false
      String :message, text: true, null: false
      DateTime :created_at, null: false

      index [:job_id, :created_at]
    end
  end
end
