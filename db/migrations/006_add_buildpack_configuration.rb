# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:build_targets) do
      add_column :builder, String
      add_column :buildpacks_json, String, text: true
    end
  end
end
