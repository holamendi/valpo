# frozen_string_literal: true

require "test_helper"

class ValpoDomainTest < Minitest::Test
  include ValpoTestDatabase

  def test_normalizes_hostname
    project = Valpo::Project.create(name: "hello")

    domain = Valpo::Domain.create(project_id: project.id, hostname: "Hello.Example.COM")

    assert_equal "hello.example.com", domain.hostname
    assert_equal "unknown", domain.tls_status
  end

  def test_validates_hostname
    project = Valpo::Project.create(name: "hello")

    error = assert_raises Sequel::ValidationFailed do
      Valpo::Domain.create(project_id: project.id, hostname: "not a host")
    end

    assert_match "hostname", error.message
  end
end
