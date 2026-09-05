# frozen_string_literal: true

require "test_helper"

class ValpoDatabaseTest < Minitest::Test
  include ValpoTestDatabase

  def test_sqlite_pragmas_are_set_for_valpo_runtime
    assert_equal "wal", pragma(:journal_mode)
    assert_equal 2, pragma(:auto_vacuum)
    assert_equal 1, pragma(:foreign_keys)
    assert_equal 1, pragma(:synchronous)
    assert_equal 5000, pragma(:busy_timeout)
    assert_equal 1000, pragma(:wal_autocheckpoint)
    assert_equal :immediate, db.transaction_mode
  end

  def test_foreign_keys_are_enforced
    assert_raises(Sequel::ForeignKeyConstraintViolation) do
      db[:releases].insert(
        id: "rel_01900000000070008000000000000000",
        service_id: "svc_01900000000070008000000000000000",
        version: 1,
        source_type: "registry",
        status: "pending",
        created_at: Time.now.utc
      )
    end
  end

  def test_lifecycle_states_are_enforced_for_dataset_updates
    service = create_app_service
    release = create_release(service:)
    job = Valpo::Jobs::Queue.new.enqueue("system_check")
    domain = create_domain(service:)
    platform_domain = create_platform_domain
    managed = create_managed_service(project: service.project, name: "database")
    dependency = Valpo::ServiceDependency.create(
      service_id: service.id,
      dependency_service_id: managed.id,
      status: "active"
    )

    {
      services: service.id,
      releases: release.id,
      jobs: job.id,
      domains: domain.id,
      platform_domains: platform_domain.id,
      service_dependencies: dependency.id
    }.each do |table, id|
      assert_raises(Sequel::CheckConstraintViolation, table.to_s) do
        db[table].where(id:).update(status: "impossible")
      end
    end
  end

  def test_single_active_resource_indexes_are_enforced
    service = create_app_service
    first = create_release(service:)
    second = create_release(service:, image: "example/app:v2")
    first.activate!

    assert_raises(Sequel::UniqueConstraintViolation) do
      db[:releases].where(id: second.id).update(status: "active")
    end

    create_platform_domain(hostname: "apps.example.com")
    candidate = create_platform_domain(hostname: "next.example.com", active: false)
    assert_raises(Sequel::UniqueConstraintViolation) do
      db[:platform_domains].where(id: candidate.id).update(active: true)
    end

    assert_raises(Sequel::CheckConstraintViolation) do
      db[:platform_domains].where(id: candidate.id).update(status: "pending", active: true)
    end
  end

  private

  def pragma(name)
    row = db.fetch("PRAGMA #{name}").first
    row.values.fetch(0)
  end
end
