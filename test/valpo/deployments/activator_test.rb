# frozen_string_literal: true

require "test_helper"

class ValpoDeploymentsActivatorTest < Minitest::Test
  include ValpoTestDatabase

  def test_restores_routes_when_the_database_cutover_fails
    app = create_app_service(status: "running")
    active = create_release(
      service: app,
      status: "active",
      container_name: "old",
      route_target: "127.0.0.1:20000"
    )
    candidate = create_release(
      service: app,
      status: "ready",
      container_name: "new",
      route_target: "127.0.0.1:20001"
    )
    reconciler = RecordingReconciler.new
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")

    error = assert_raises Valpo::ValidationError do
      Valpo::Deployments::Activator.new(caddy_reconciler: reconciler).activate(
        service: FailingService.new,
        release: candidate,
        runtime: Object.new,
        queue:,
        job_id: job.id
      )
    end

    assert_equal "cutover failed", error.message
    assert_equal [candidate, nil], reconciler.overrides
    assert_equal "active", active.refresh.status
    assert_equal "ready", candidate.refresh.status
  end

  def test_ready_activation_caddy_failure_restores_routes_and_removes_only_the_candidate
    app = create_app_service(status: "running")
    create_domain(service: app)
    active = create_release(
      service: app,
      status: "active",
      container_name: "old",
      route_target: "127.0.0.1:20000"
    )
    candidate = create_release(
      service: app,
      status: "ready",
      container_name: "new",
      route_target: "127.0.0.1:20001"
    )
    docker = ValpoTestSupport::FakeDocker.new
    caddy = ValpoTestSupport::FakeCaddy.new(fail_reloads: 1)

    assert_raises Valpo::ValidationError do
      run_ready_activation(app:, docker:, caddy:)
    end

    assert_equal "active", active.refresh.status
    assert_equal "ready", candidate.refresh.status
    assert_nil candidate.container_name
    assert_nil candidate.route_target
    assert docker.executed?(:stop, "new")
    assert docker.executed?(:rm, "new", true)
    assert_equal "127.0.0.1:20000", caddy.routes.first.fetch(:upstream)
  end

  def test_ready_activation_database_failure_removes_candidate_after_rolling_back_cutover
    app = create_app_service(status: "running")
    active = create_release(
      service: app,
      status: "active",
      container_name: "old",
      route_target: "127.0.0.1:20000"
    )
    candidate = create_release(
      service: app,
      status: "ready",
      container_name: "new",
      route_target: "127.0.0.1:20001"
    )
    connection = Valpo::Database.connection
    connection.run(<<~SQL)
      CREATE TRIGGER fail_ready_activation
      BEFORE UPDATE OF status ON releases
      WHEN OLD.id = #{connection.literal(candidate.id)} AND NEW.status = 'active'
      BEGIN
        SELECT RAISE(FAIL, 'injected activation failure');
      END
    SQL
    docker = ValpoTestSupport::FakeDocker.new

    assert_raises Sequel::DatabaseError do
      run_ready_activation(app:, docker:, caddy: ValpoTestSupport::FakeCaddy.new)
    end

    assert_equal "active", active.refresh.status
    assert_equal "ready", candidate.refresh.status
    assert_nil candidate.container_name
    assert_nil candidate.route_target
  ensure
    connection&.run("DROP TRIGGER IF EXISTS fail_ready_activation")
  end

  def test_ready_activation_preserves_candidate_metadata_when_cleanup_stop_or_remove_fails
    %i[stop rm].each_with_index do |failure, index|
      app = create_app_service(
        project: create_project(name: "cleanup-#{index}"),
        status: "running"
      )
      create_release(
        service: app,
        status: "active",
        container_name: "old-#{index}",
        route_target: "127.0.0.1:#{20_000 + index}"
      )
      candidate = create_release(
        service: app,
        status: "ready",
        container_name: "new-#{index}",
        route_target: "127.0.0.1:#{21_000 + index}"
      )
      queue = Valpo::Jobs::Queue.new
      job = queue.enqueue("system_check")
      docker = ValpoTestSupport::FakeDocker.new(fail_on: failure)
      caddy = ValpoTestSupport::FakeCaddy.new(fail_reloads: 1)
      runtime = runtime_for(docker:, queue:, job_id: job.id)
      activator = activator_for(caddy:)

      assert_raises Valpo::ValidationError do
        activator.activate_ready(service: app, runtime:, queue:, job_id: job.id)
      end

      assert_equal "ready", candidate.refresh.status
      assert_equal "new-#{index}", candidate.container_name
      assert queue.events(job.id).any? {
        it.stream == "stderr" && it.message.include?("Could not remove failed activation candidate")
      }
    end
  end

  def test_ready_activation_succeeds_with_warning_when_retiring_the_active_release_fails
    %i[stop rm].each_with_index do |failure, index|
      app = create_app_service(
        project: create_project(name: "ready-retirement-#{index}"),
        status: "running"
      )
      previous = create_release(
        service: app,
        status: "active",
        container_name: "old-#{index}",
        route_target: "127.0.0.1:#{20_000 + index}"
      )
      candidate = create_release(
        service: app,
        status: "ready",
        container_name: "new-#{index}",
        route_target: "127.0.0.1:#{21_000 + index}"
      )
      queue = Valpo::Jobs::Queue.new
      job = queue.enqueue("system_check")
      docker = ValpoTestSupport::FakeDocker.new(fail_on: failure)

      activated = activator_for(caddy: ValpoTestSupport::FakeCaddy.new).activate_ready(
        service: app,
        runtime: runtime_for(docker:, queue:, job_id: job.id),
        queue:,
        job_id: job.id
      )

      assert_equal candidate.id, activated.id
      assert_equal "active", candidate.refresh.status
      assert_equal "inactive", previous.refresh.status
      assert_equal "old-#{index}", previous.container_name
      assert_equal "running", app.refresh.status
      assert queue.events(job.id).any? {
        it.stream == "stderr" && it.message.include?("Could not retire release 1")
      }
    end
  end

  private

  def run_ready_activation(app:, docker:, caddy:)
    queue = Valpo::Jobs::Queue.new
    job = queue.enqueue("system_check")
    activator_for(caddy:).activate_ready(
      service: app,
      runtime: runtime_for(docker:, queue:, job_id: job.id),
      queue:,
      job_id: job.id
    )
  end

  def activator_for(caddy:)
    Valpo::Deployments::Activator.new(
      caddy_reconciler: Valpo::Caddy::Reconciler.new(caddy:)
    )
  end

  def runtime_for(docker:, queue:, job_id:)
    Valpo::Deployments::Runtime.new(
      config: VALPO_TEST_CONFIG,
      docker:,
      queue:,
      job_id:
    )
  end

  class RecordingReconciler
    attr_reader :overrides

    def initialize
      @overrides = []
    end

    def apply(override_release: nil, **)
      overrides << override_release
      true
    end
  end

  class FailingService
    def update(status:)
      raise Valpo::ValidationError, "cutover failed"
    end
  end
end
