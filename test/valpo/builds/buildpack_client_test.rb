# frozen_string_literal: true

require "test_helper"

class ValpoBuildsBuildpackClientTest < Minitest::Test
  def test_build_command_pins_builder_and_named_caches
    command = client.build_command(
      image: "valpo/acme/web:abc",
      context: "/tmp/source",
      builder: "example/builder@sha256:abc",
      build_cache: "valpo-cnb-build-target_1",
      launch_cache: "valpo-cnb-launch-target_1",
      default_process: "web"
    )

    assert_equal(
      [
        "pack", "--no-color", "build", "valpo/acme/web:abc",
        "--path", "/tmp/source",
        "--builder", "example/builder@sha256:abc",
        "--pull-policy", "if-not-present",
        "--default-process", "web",
        "--cache",
        "type=build;format=volume;name=valpo-cnb-build-target_1;" \
          "type=launch;format=volume;name=valpo-cnb-launch-target_1"
      ],
      command
    )
    refute_includes command, "--trust-builder"
  end

  def test_worker_build_can_leave_the_default_process_to_the_image
    command = client.build_command(
      image: "valpo/acme/worker:abc",
      context: "/tmp/source",
      builder: "example/builder@sha256:abc",
      build_cache: "build-cache",
      launch_cache: "launch-cache",
      default_process: nil
    )

    refute_includes command, "--default-process"
  end

  def test_rejects_unsupported_hosts_before_starting_pack
    error = assert_raises Valpo::ValidationError do
      Valpo::Builds::BuildpackClient.new(platform: "darwin", host_cpu: "arm64").ensure_supported!
    end

    assert_match "require Linux on amd64 or arm64", error.message
  end

  def test_accepts_supported_linux_architectures
    Valpo::Builds::BuildpackClient.new(platform: "aarch64-linux", host_cpu: "aarch64").ensure_supported!
    Valpo::Builds::BuildpackClient.new(platform: "x86_64-linux", host_cpu: "x86_64").ensure_supported!
  end

  private

  def client
    @client ||= Valpo::Builds::BuildpackClient.new(
      binary: "pack",
      platform: "x86_64-linux",
      host_cpu: "x86_64"
    )
  end
end
