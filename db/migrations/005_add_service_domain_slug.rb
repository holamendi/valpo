# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:services) do
      add_column :domain_slug, String, size: 63
      add_index :domain_slug, unique: true
    end
  end
end
