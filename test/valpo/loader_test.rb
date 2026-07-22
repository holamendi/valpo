# frozen_string_literal: true

require "test_helper"

class ValpoLoaderTest < Minitest::Test
  include ValpoTestDatabase

  def test_all_valpo_constants_follow_zeitwerk_conventions
    Valpo.loader.eager_load

    assert defined?(Valpo::API::App)
    assert defined?(Valpo::CLI)
    assert defined?(Valpo::Project)
    assert defined?(Valpo::Builds::Orchestrator)
    assert defined?(Valpo::Caddy::Reconciler)
    assert defined?(Valpo::Deployments::Lifecycle)
    assert defined?(Valpo::Deployments::Activator)
    assert defined?(Valpo::Deployments::Repairer)
    assert defined?(Valpo::Domains::Orchestrator)
    assert defined?(Valpo::System::Repairer)
    assert defined?(Valpo::Jobs::HandlerRegistry)
    assert defined?(Valpo::Manifests::Planner)
    assert defined?(Valpo::Services::Registry)
    assert defined?(Valpo::Services::Creator)
    assert defined?(Valpo::Services::ManagedLifecycle)
    assert defined?(Valpo::Services::DependencyManager)
    assert defined?(Valpo::Sources::GitHub)
  end
end
