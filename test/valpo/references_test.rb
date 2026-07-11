# frozen_string_literal: true

require "test_helper"
require "valpo/references"

class ValpoReferencesTest < Minitest::Test
  include ValpoTestDatabase

  def test_resolves_typed_id_and_project_service_reference
    service = create_app_service
    assert_equal service.id, Valpo::References.service(service.id).id
    assert_equal service.id, Valpo::References.service("hello/web").id
    assert_raises(Valpo::ValidationError) { Valpo::References.service("web") }
    assert_raises(Valpo::ValidationError) { Valpo::References.service("svc_../../projects") }
  end
end
