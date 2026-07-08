# frozen_string_literal: true

require "json"
require "rack/test"
require "test_helper"
require "valpo/api/app"

class ValpoAPIAppTest < Minitest::Test
  include Rack::Test::Methods
  include ValpoTestDatabase

  def app
    Valpo::API::App
  end

  def test_health
    get "/health"

    assert_equal 200, last_response.status
    assert_equal true, json.fetch("ok")
  end

  def test_project_create_list_and_show
    post "/projects", JSON.generate(name: "hello"), "CONTENT_TYPE" => "application/json"

    assert_equal 201, last_response.status
    project = json
    assert_equal "hello", project.fetch("name")
    assert_equal "container", project.fetch("type")

    get "/projects"
    assert_equal ["hello"], json.map { |item| item.fetch("name") }

    get "/projects/#{project.fetch("id")}"
    assert_equal "hello", json.fetch("name")

    get "/projects/hello"
    assert_equal project.fetch("id"), json.fetch("id")
  end

  def test_project_delete_enqueues_cleanup_job
    project = Valpo::Project.create(name: "hello")

    delete "/projects/hello"

    assert_equal 202, last_response.status
    assert_equal "delete_project", json.fetch("type")
    assert_equal project.id, json.fetch("payload").fetch("project_id")
  end

  def test_project_validation_error
    post "/projects", JSON.generate(name: "Hello"), "CONTENT_TYPE" => "application/json"

    assert_equal 422, last_response.status
    assert_match "lowercase", json.fetch("message")
  end

  def test_job_reads_and_events
    job = Valpo::Jobs::Queue.new.enqueue("system_check", source: "test")

    get "/jobs"
    assert_equal [job[:id]], json.map { |item| item.fetch("id") }

    get "/jobs/#{job[:id]}"
    assert_equal "system_check", json.fetch("type")
    assert_equal({ "source" => "test" }, json.fetch("payload"))

    get "/jobs/#{job[:id]}/events"
    assert_equal ["Job queued"], json.map { |item| item.fetch("message") }
  end

  def test_system_repair_enqueues_job
    post "/system/repair"

    assert_equal 202, last_response.status
    assert_equal "repair_system", json.fetch("type")
  end

  def test_deploy_rollback_stop_and_restart_enqueue_jobs
    project = Valpo::Project.create(name: "hello")

    post "/projects/hello/deployments",
         JSON.generate(image: "ghcr.io/example/hello:latest", internal_port: 3000, healthcheck_path: "/health"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 202, last_response.status
    assert_equal "deploy_registry_image", json.fetch("type")
    assert_equal project.id, json.fetch("payload").fetch("project_id")
    assert_equal 3000, json.fetch("payload").fetch("internal_port")
    complete_job(json.fetch("id"))

    post "/projects/hello/rollback"
    assert_equal 202, last_response.status
    assert_equal "rollback_release", json.fetch("type")
    complete_job(json.fetch("id"))

    post "/projects/hello/stop"
    assert_equal 202, last_response.status
    assert_equal "stop_project", json.fetch("type")
    complete_job(json.fetch("id"))

    post "/projects/hello/restart"
    assert_equal 202, last_response.status
    assert_equal "restart_project", json.fetch("type")
  end

  def test_deploy_validates_request_before_enqueueing_job
    Valpo::Project.create(name: "hello")

    post "/projects/hello/deployments",
         JSON.generate(image: "ghcr.io/example/hello:latest", internal_port: 0),
         "CONTENT_TYPE" => "application/json"

    assert_equal 422, last_response.status
    assert_match "between 1 and 65535", json.fetch("message")

    post "/projects/hello/deployments",
         JSON.generate(image: "ghcr.io/example/hello:latest", internal_port: 3000, healthcheck_path: "health"),
         "CONTENT_TYPE" => "application/json"

    assert_equal 422, last_response.status
    assert_match "healthcheck_path", json.fetch("message")

    assert_empty Valpo::Job.where(type: "deploy_registry_image").all
  end

  def test_deploy_rejects_second_active_project_operation
    Valpo::Project.create(name: "hello")

    post "/projects/hello/deployments",
         JSON.generate(image: "ghcr.io/example/hello:v1", internal_port: 3000),
         "CONTENT_TYPE" => "application/json"

    assert_equal 202, last_response.status

    post "/projects/hello/deployments",
         JSON.generate(image: "ghcr.io/example/hello:v2", internal_port: 3000),
         "CONTENT_TYPE" => "application/json"

    assert_equal 409, last_response.status
    assert_match "already has an active deploy_registry_image job", json.fetch("message")
    assert_equal 1, Valpo::Job.where(type: "deploy_registry_image").count
  end

  def test_domain_change_rejects_active_project_operation
    Valpo::Project.create(name: "hello")
    Valpo::Jobs::Queue.new.enqueue_project_operation(
      "deploy_registry_image",
      project_id: Valpo::Project.find_by_id_or_name("hello").id,
      payload: { image: "ghcr.io/example/hello:v1", internal_port: 3000 }
    )

    post "/projects/hello/domains", JSON.generate(hostname: "hello.example.com"), "CONTENT_TYPE" => "application/json"

    assert_equal 409, last_response.status
    assert_match "already has an active deploy_registry_image job", json.fetch("message")
    assert_empty Valpo::Domain.all
  end

  def test_container_actions_reject_static_projects
    Valpo::Project.create(name: "site", type: "static")

    post "/projects/site/deployments",
         JSON.generate(image: "ghcr.io/example/site:latest", internal_port: 3000),
         "CONTENT_TYPE" => "application/json"

    assert_equal 422, last_response.status
    assert_match "Only container projects", json.fetch("message")
  end

  def test_releases_are_listed_for_project
    project = Valpo::Project.create(name: "hello")
    Valpo::Release.create(project_id: project.id, source_type: "registry", source_ref: "ghcr.io/example/hello:v1")

    get "/projects/hello/releases"

    assert_equal 200, last_response.status
    assert_equal ["ghcr.io/example/hello:v1"], json.map { |release| release.fetch("source_ref") }
  end

  def test_domain_create_list_and_delete
    Valpo::Project.create(name: "hello")

    post "/projects/hello/domains", JSON.generate(hostname: "Hello.Example.com"), "CONTENT_TYPE" => "application/json"

    assert_equal 201, last_response.status
    domain = json.fetch("domain")
    assert_equal "hello.example.com", domain.fetch("hostname")
    assert_equal "apply_caddy_config", json.fetch("job").fetch("type")
    complete_job(json.fetch("job").fetch("id"))

    get "/projects/hello/domains"
    assert_equal ["hello.example.com"], json.map { |item| item.fetch("hostname") }

    delete "/projects/hello/domains/#{domain.fetch("id")}"
    assert_equal 200, last_response.status
    assert_equal true, json.fetch("deleted")

    get "/projects/hello/domains"
    assert_empty json
  end

  def test_logs_delegate_to_deploy_orchestrator
    project = Valpo::Project.create(name: "hello")
    fake = FakeLogOrchestrator.new

    Valpo::Deployments::Orchestrator.stub(:new, fake) do
      get "/projects/hello/logs?tail=5"
    end

    assert_equal 200, last_response.status
    assert_equal "app log\n", json.fetch("stdout")
    assert_equal project.id, fake.project_id
    assert_equal 5, fake.tail
  end

  def test_logs_validates_tail
    Valpo::Project.create(name: "hello")

    get "/projects/hello/logs?tail=abc"

    assert_equal 422, last_response.status
    assert_match "tail must be an integer", json.fetch("message")

    get "/projects/hello/logs?tail=0"

    assert_equal 422, last_response.status
    assert_match "tail must be greater than 0", json.fetch("message")
  end

  def test_not_found_response
    get "/jobs/missing"

    assert_equal 404, last_response.status
    assert_equal "not_found", json.fetch("error")
  end

  private

  def json
    JSON.parse(last_response.body)
  end

  def complete_job(job_id)
    queue = Valpo::Jobs::Queue.new
    locked = queue.lock_next("api-test-worker")
    assert_equal job_id, locked.id
    queue.succeed(job_id, worker_id: "api-test-worker")
  end

  class FakeLogOrchestrator
    attr_reader :project_id, :tail

    def app_logs(project_id:, tail:)
      @project_id = project_id
      @tail = tail
      { "stdout" => "app log\n", "stderr" => "" }
    end
  end
end
