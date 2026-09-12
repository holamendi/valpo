# frozen_string_literal: true

require "test_helper"

class ValpoAPIV1SerializerTest < Minitest::Test
  def test_fields_are_allowlisted_and_computed_fields_receive_the_record
    serializer = Class.new(Valpo::API::V1::Serializer) do
      fields :id, :enabled, :optional
      field(:type) { it.fetch(:kind) }
    end

    assert_equal({id: "123", enabled: false, optional: nil, type: "web"},
      serializer.render({id: "123", enabled: false, kind: "web", secret: "hidden"}))
    assert_equal [], serializer.render_many([])
    assert_equal [{id: "123", enabled: nil, optional: nil, type: "web"}],
      serializer.render_many([{id: "123", kind: "web"}])
  end

  def test_nested_and_computed_timestamps_are_normalized_without_mutating_inputs
    serializer = Class.new(Valpo::API::V1::Serializer) do
      fields :created_at
      field(:metadata) { it.fetch(:metadata) }
    end
    timestamp = Time.new(2026, 9, 12, 12, 30, 0, "+02:00").freeze
    metadata = {"events" => [timestamp, Date.new(2026, 9, 12), DateTime.iso8601("2026-09-12T12:30:00+02:00"), nil, false]}
    output = serializer.render({created_at: timestamp, metadata:})

    assert_equal "2026-09-12T10:30:00Z", output.fetch(:created_at)
    assert_equal ["2026-09-12T10:30:00Z", "2026-09-12", "2026-09-12T10:30:00+00:00", nil, false],
      output.fetch(:metadata).fetch("events")
    assert_equal 7200, timestamp.utc_offset
    assert_same timestamp, metadata.fetch("events").first
  end

  def test_subclass_fields_do_not_change_parent_or_sibling_serializers
    parent = Class.new(Valpo::API::V1::Serializer) { fields :id }
    child = Class.new(parent) { field(:id) { "public-#{it.fetch(:id)}" } }
    sibling = Class.new(parent) { fields :name }

    assert_equal({id: "123"}, parent.render({id: "123"}))
    assert_equal({id: "public-123"}, child.render({id: "123"}))
    assert_equal({id: "123", name: "test"}, sibling.render({id: "123", name: "test"}))
  end

  def test_computed_field_errors_are_not_silently_replaced_with_null
    serializer = Class.new(Valpo::API::V1::Serializer) do
      field(:name) { it.fetch(:name) }
    end

    assert_raises(KeyError) { serializer.render({}) }
  end

  def test_conditional_fields_are_omitted_without_reading_or_computing_values
    serializer = Class.new(Valpo::API::V1::Serializer) do
      field :name, if: -> { it.fetch(:include_details) }
      field(:details, if: -> { it.fetch(:include_details) }) { it.fetch(:details) }
    end
    record = {include_details: false}
    record.define_singleton_method(:[]) { |_key| raise "Omitted fields must not be read" }

    assert_equal({}, serializer.render(record))
    assert_equal({}, serializer.render({include_details: nil}))
    assert_equal({name: "test", details: nil},
      serializer.render({include_details: true, name: "test", details: nil}))
  end

  def test_collection_conditions_are_evaluated_per_record
    serializer = Class.new(Valpo::API::V1::Serializer) do
      fields :id
      field(:name, if: -> { it.fetch(:visible) }) { it.fetch(:name) }
    end

    assert_equal [{id: 1}, {id: 2, name: "visible"}], serializer.render_many([
      {id: 1, visible: false}, {id: 2, visible: true, name: "visible"}
    ])
  end

  def test_conditional_fields_are_inherited_and_can_be_overridden
    parent = Class.new(Valpo::API::V1::Serializer) do
      field :name, if: -> { it.fetch(:visible) }
    end
    child = Class.new(parent) { fields :name }
    sibling = Class.new(parent)
    record = {name: "test", visible: false}

    assert_equal({}, parent.render(record))
    assert_equal({}, sibling.render(record))
    assert_equal({name: "test"}, child.render(record))
  end
end
