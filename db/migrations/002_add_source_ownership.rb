# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:sources) do
      add_foreign_key :owner_service_id, :services, type: String, size: 40, on_delete: :cascade
      add_index :owner_service_id, unique: true
      set_column_default :ref, "HEAD"
    end

    alter_table(:build_targets) do
      add_foreign_key :owner_service_id, :services, type: String, size: 40, on_delete: :cascade
      add_index :owner_service_id, unique: true
    end
  end

  down do
    alter_table(:build_targets) do
      drop_index :owner_service_id
      drop_column :owner_service_id
    end

    alter_table(:sources) do
      set_column_default :ref, "main"
      drop_index :owner_service_id
      drop_column :owner_service_id
    end
  end
end
