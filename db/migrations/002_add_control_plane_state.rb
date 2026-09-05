# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:control_plane_states) do
      Integer :id, primary_key: true
      DateTime :api_bootstrapped_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      constraint(:control_plane_states_singleton) { id =~ 1 }
    end

    timestamp = Time.now.utc
    first_credential_at = from(:api_credentials).min(:created_at)
    from(:control_plane_states).insert(
      id: 1,
      api_bootstrapped_at: first_credential_at,
      created_at: timestamp,
      updated_at: timestamp
    )
  end

  down do
    drop_table(:control_plane_states)
  end
end
