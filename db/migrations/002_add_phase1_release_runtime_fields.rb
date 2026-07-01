# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:releases) do
      add_column :internal_port, Integer
      add_column :healthcheck_path, String
      add_column :container_name, String
      add_column :route_target, String

      add_index :container_name
    end
  end
end
