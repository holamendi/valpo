# frozen_string_literal: true

require "test_helper"

class ValpoReferencesTest < Minitest::Test
  include ValpoTestDatabase

  def test_resolves_typed_id_and_project_scoped_service_name
    service = create_app_service
    assert_equal service.id, Valpo::References.service(service.id).id
    assert_equal service.id, Valpo::References.service("web", project: "hello").id
    assert_raises(Valpo::ValidationError) { Valpo::References.service("web") }
    assert_raises(Valpo::ValidationError) { Valpo::References.service("hello/web", project: "hello") }
    assert_raises(Valpo::ValidationError) { Valpo::References.service("svc_../../projects") }
  end
end
