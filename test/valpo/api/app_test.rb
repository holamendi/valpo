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

  def test_not_found_response
    get "/jobs/missing"

    assert_equal 404, last_response.status
    assert_equal "not_found", json.fetch("error")
  end

  private

  def json
    JSON.parse(last_response.body)
  end
end
