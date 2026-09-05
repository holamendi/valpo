# frozen_string_literal: true

require "test_helper"

class ValpoDeploymentsRuntimeTest < Minitest::Test
  def test_image_inspection_does_not_publish_environment_values
    docker = Object.new
    docker.define_singleton_method(:image_inspect_command) { ["inspect", it] }
    docker.define_singleton_method(:execute) do |_command|
      {success: true, stdout: JSON.generate([{"Id" => "sha256:abc", "Config" => {"Env" => ["SECRET=private-value"], "ExposedPorts" => {"3000/tcp" => {}}}}]), stderr: "", status: 0}
    end
    events = []
    queue = Object.new
    queue.define_singleton_method(:event) { |*arguments| events << arguments }
    metadata = Valpo::Deployments::Runtime.new(config: VALPO_TEST_CONFIG, docker:, queue:, job_id: "test").inspect_image_metadata("test/image")
    assert_equal [3000], metadata.exposed_tcp_ports
    assert_equal "sha256:abc", metadata.digest
    assert_empty events
  end
end
