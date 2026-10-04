# frozen_string_literal: true

require "test_helper"
require "securerandom"

class AppStorageSmokeTest < Minitest::Test
  include ValpoTestDatabase

  def test_non_root_data_survives_real_container_replacement
    skip "Set VALPO_TEST_APP_STORAGE=1 to exercise real Docker" unless ENV["VALPO_TEST_APP_STORAGE"] == "1"

    docker = Valpo::Docker::Client.new(binary: ENV.fetch("VALPO_TEST_DOCKER_BINARY", "docker"))
    image = "valpo-storage-smoke:#{SecureRandom.hex(6)}"
    service = create_app_service(name: "storage-smoke-#{SecureRandom.hex(3)}", kind: "worker")
    config = Valpo::AppServiceConfig[service.id]
    marker = "real-persistence-#{SecureRandom.hex(8)}"
    config.update(storage_path: "/data", command: ["sh", "-c", "printf %s #{marker} > /data/marker; sleep 180"])
    runtime = Valpo::Deployments::Runtime.new(config: VALPO_TEST_CONFIG, docker:)
    volume = Valpo::Services::AppStorage.volume_name(service)
    names = []

    begin
      Dir.mktmpdir("valpo-storage-image") do
        dockerfile = File.join(it, "Dockerfile")
        File.write(dockerfile, "FROM alpine:3.21\nRUN adduser -D app && mkdir /data && chown app:app /data\nUSER app\n")
        built = docker.execute(docker.build_command(dockerfile:, tag: image, context: it))
        assert built.fetch(:success), built.fetch(:stderr)
      end
      name = runtime.start_release_container(create_release(service:, image:))
      names << name
      20.times do
        break if docker.execute(docker.exec_command(name, "test", "-f", "/data/marker")).fetch(:success)
        sleep 0.2
      end
      result = docker.execute(docker.exec_command(name, "cat", "/data/marker"))
      assert result.fetch(:success), result.fetch(:stderr)
      assert_equal marker, result.fetch(:stdout)
      assert_equal "app", runtime.inspect_container(name).dig("Config", "User")
      assert_equal volume, runtime.inspect_container(name).fetch("Mounts").find { it["Destination"] == "/data" }.fetch("Name")

      runtime.stop_container(name, ignore_missing: false)
      names.delete(name)
      config.update(command: ["sh", "-c", "sleep 180"])
      name = runtime.start_release_container(create_release(service:, image:))
      names << name
      assert_equal marker, docker.execute(docker.exec_command(name, "cat", "/data/marker")).fetch(:stdout)
      actual = JSON.parse(docker.execute(docker.volume_inspect_command(volume)).fetch(:stdout)).first
      assert_equal service.id, actual.fetch("Labels").fetch("valpo.service_id")
      assert_equal service.project_id, actual.fetch("Labels").fetch("valpo.project_id")
      assert_equal "local", actual.fetch("Driver")
      runtime.stop_container(name, ignore_missing: false)
      names.delete(name)
      runtime.remove_app_storage(service)
      refute docker.execute(docker.volume_inspect_command(volume)).fetch(:success)
    ensure
      names.each { runtime.cleanup_container(it) }
      runtime.remove_app_storage(service)
      docker.execute(docker.image_rm_command(image))
    end
  end
end
