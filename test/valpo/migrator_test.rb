# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "test_helper"

class ValpoMigratorTest < Minitest::Test
  include ValpoTestDatabase

  def test_unified_service_tables_exist
    assert_includes db.tables, :projects
    assert_includes db.tables, :sources
    assert_includes db.tables, :build_targets
    assert_includes db.tables, :services
    assert_includes db.tables, :app_service_configs
    assert_includes db.tables, :managed_service_configs
    assert_includes db.tables, :service_dependencies
    assert_includes db.tables, :releases
    assert_includes db.tables, :domains
    assert_includes db.tables, :platform_domains
    assert_includes db.tables, :github_app_setups
    assert_includes db.tables, :github_webhook_deliveries
    assert_includes db.tables, :jobs
    assert_includes db.tables, :job_events
    assert_includes db.tables, :control_plane_states
  end

  def test_bootstrap_schema_is_frozen_and_migration_versions_are_contiguous
    bootstrap = File.join(Valpo::SchemaInfo::MIGRATIONS_PATH, Valpo::SchemaInfo::BOOTSTRAP_FILENAME)

    assert Valpo::SchemaInfo.validate_migrations!
    assert_equal [1, 2, 3, 4, 5], Valpo::SchemaInfo.versions
    assert_equal 5, Valpo::SchemaInfo.latest
    assert_equal Valpo::SchemaInfo::BOOTSTRAP_SHA256, Digest::SHA256.file(bootstrap).hexdigest
    assert_includes db.schema(:sources).to_h, :owner_service_id
    assert_includes db.schema(:build_targets).to_h, :owner_service_id
    assert_includes db.schema(:domains).to_h, :kind
    assert_includes db.schema(:domains).to_h, :status

    project = create_project
    db[:sources].insert(
      id: Valpo::Identifier.generate(:source),
      project_id: project.id,
      name: "backend",
      provider: "github",
      repository: "acme/backend",
      created_at: Time.now.utc,
      updated_at: Time.now.utc
    )

    assert_equal "HEAD", db[:sources].where(project_id: project.id, name: "backend").get(:ref)
  end

  def test_incremental_migration_policy_accepts_new_contiguous_versions
    Dir.mktmpdir("valpo-migrations") do
      copy_bootstrap(it)
      File.write(File.join(it, "002_add_example.rb"), "# future migration\n")

      assert Valpo::SchemaInfo.validate_migrations!(path: it)
      assert_equal [1, 2], Valpo::SchemaInfo.versions(path: it)
      assert_equal 2, Valpo::SchemaInfo.latest(path: it)
    end
  end

  def test_service_domain_slugs_are_unique_and_optional_until_allocated
    first = create_app_service
    second = create_app_service(project: first.project, name: "other")

    assert_nil first.domain_slug
    assert_nil second.domain_slug
    db[:services].where(id: first.id).update(domain_slug: "hello-web")
    assert_raises(Sequel::UniqueConstraintViolation) do
      db[:services].where(id: second.id).update(domain_slug: "hello-web")
    end
  end

  def test_control_plane_state_migration_closes_bootstrap_for_existing_credentials
    Dir.mktmpdir("valpo-bootstrap-state") do
      database = Sequel.sqlite(File.join(it, "valpo.sqlite3"))
      Valpo::Migrator.run(db: database, target: 1)
      timestamp = Time.now.utc
      database[:api_credentials].insert(
        id: Valpo::Identifier.generate(:api_credential),
        name: "existing-admin",
        token_prefix: "valpo_existing",
        token_digest: "a" * 64,
        scopes_json: JSON.generate(["admin"]),
        created_at: timestamp,
        updated_at: timestamp
      )

      Valpo::Migrator.run(db: database)

      state = database[:control_plane_states].where(id: 1).first
      assert_equal timestamp.to_i, state.fetch(:api_bootstrapped_at).to_i
    ensure
      database&.disconnect
    end
  end

  def test_lifecycle_migration_reports_unknown_states_before_changing_schema
    Dir.mktmpdir("valpo-invalid-lifecycle") do
      database = Sequel.sqlite(File.join(it, "valpo.sqlite3"))
      Valpo::Migrator.run(db: database, target: 2)
      project_id, service_id = insert_upgrade_service(database)
      database[:services].where(id: service_id).update(status: "lost")

      error = assert_raises(Sequel::Error) { Valpo::Migrator.run(db: database) }

      assert_match "Lifecycle invariant preflight failed", error.message
      assert_match "services: #{service_id}=\"lost\"", error.message
      assert_equal 2, database[:schema_info].get(:version)
      assert_equal project_id, database[:projects].get(:id)
    ensure
      database&.disconnect
    end
  end

  def test_lifecycle_migration_repairs_duplicate_active_resources
    Dir.mktmpdir("valpo-duplicate-lifecycle") do
      database = Sequel.sqlite(File.join(it, "valpo.sqlite3"))
      Valpo::Migrator.run(db: database, target: 2)
      _project_id, service_id = insert_upgrade_service(database)
      timestamp = Time.now.utc
      2.times do
        database[:releases].insert(
          id: "rel_0190000000007000800000000000000#{it}",
          service_id:,
          version: it + 1,
          source_type: "registry",
          status: "active",
          build_metadata_json: "{}",
          artifact_available: true,
          environment_revision: 0,
          created_at: timestamp + it
        )
        database[:platform_domains].insert(
          id: "pdm_0190000000007000800000000000000#{it}",
          hostname: "apps#{it}.example.com",
          status: "verified",
          active: true,
          verification_token: "token#{it}",
          verified_at: timestamp + it,
          created_at: timestamp + it,
          updated_at: timestamp + it
        )
      end

      _out, warning = capture_io { Valpo::Migrator.run(db: database) }

      assert_match "repaired duplicate active releases", warning
      assert_match "repaired active platform domains", warning
      assert_equal ["rel_01900000000070008000000000000001"], database[:releases].where(status: "active").select_map(:id)
      assert_equal 1, database[:platform_domains].where(active: true).count
      assert_equal 5, database[:schema_info].get(:version)
    ensure
      database&.disconnect
    end
  end

  def test_job_recovery_migration_backfills_indexed_scope_and_generation
    Dir.mktmpdir("valpo-job-recovery") do
      database = Sequel.sqlite(File.join(it, "valpo.sqlite3"))
      Valpo::Migrator.run(db: database, target: 3)
      project_id, service_id = insert_upgrade_service(database)
      timestamp = Time.now.utc
      2.times do
        database[:jobs].insert(
          id: "job_0190000000007000800000000000000#{it}",
          type: "deploy_source",
          status: "queued",
          payload_json: JSON.generate(project_id:, service_id:, ref: "main"),
          progress: 0,
          created_at: timestamp + it
        )
      end

      Valpo::Migrator.run(db: database)

      jobs = database[:jobs].order(:created_at).all
      assert_equal [project_id, project_id], jobs.map { it.fetch(:project_id) }
      assert_equal [service_id, service_id], jobs.map { it.fetch(:service_id) }
      assert_equal [1, 2], jobs.map { it.fetch(:operation_generation) }
      assert_equal ["compensating", "compensating"], jobs.map { it.fetch(:recovery_strategy) }
      assert_equal 5, database[:schema_info].get(:version)
    ensure
      database&.disconnect
    end
  end

  def test_job_recovery_migration_rolls_back_from_four_to_three
    Dir.mktmpdir("valpo-job-recovery-down") do
      database = Sequel.sqlite(File.join(it, "valpo.sqlite3"))
      Valpo::Migrator.run(db: database)
      database[:jobs].insert(
        id: "job_01900000000070008000000000000000",
        type: "system_check",
        status: "queued",
        payload_json: "{}",
        progress: 0,
        attempt: 0,
        operation_generation: 1,
        recovery_strategy: "retryable",
        created_at: Time.now.utc
      )

      Valpo::Migrator.run(db: database, target: 3)

      assert_equal 3, database[:schema_info].get(:version)
      columns = database.schema(:jobs).to_h
      refute_includes columns, :project_id
      refute_includes columns, :request_fingerprint
      refute_includes columns, :heartbeat_at
      assert_raises(Sequel::CheckConstraintViolation) do
        database[:jobs].where(id: "job_01900000000070008000000000000000").update(status: "impossible")
      end
    ensure
      database&.disconnect
    end
  end

  def test_incremental_migration_policy_rejects_bootstrap_edits_and_version_gaps
    Dir.mktmpdir("valpo-migrations") do |path|
      copy_bootstrap(path)
      File.write(File.join(path, "003_skip_version.rb"), "# invalid gap\n")

      gap = assert_raises(Valpo::ValidationError) { Valpo::SchemaInfo.validate_migrations!(path:) }
      assert_match "contiguous from 001", gap.message

      File.write(File.join(path, Valpo::SchemaInfo::BOOTSTRAP_FILENAME), "# changed\n")
      changed = assert_raises(Valpo::ValidationError) { Valpo::SchemaInfo.validate_migrations!(path:) }
      assert_match "is frozen", changed.message
    end
  end

  private

  def insert_upgrade_service(database)
    timestamp = Time.now.utc
    project_id = "prj_01900000000070008000000000000000"
    service_id = "svc_01900000000070008000000000000000"
    database[:projects].insert(id: project_id, name: "upgrade", created_at: timestamp, updated_at: timestamp)
    database[:services].insert(
      id: service_id,
      project_id:,
      name: "web",
      kind: "web",
      status: "running",
      environment_revision: 0,
      created_at: timestamp,
      updated_at: timestamp
    )
    [project_id, service_id]
  end

  def copy_bootstrap(path)
    FileUtils.cp(
      File.join(Valpo::SchemaInfo::MIGRATIONS_PATH, Valpo::SchemaInfo::BOOTSTRAP_FILENAME),
      path
    )
  end
end
