# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:app_service_configs) do
      add_column :storage_path, String
    end
  end
end
