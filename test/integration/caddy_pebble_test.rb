# frozen_string_literal: true

require "test_helper"
require "open3"
require "openssl"
require "socket"

class ValpoCaddyPebbleTest < Minitest::Test
  FIXTURE_DIR = File.expand_path("../fixtures/pebble", __dir__)
  COMPOSE_FILE = File.join(FIXTURE_DIR, "compose.yml")
  HOSTS = %w[api.valpo.test web.valpo.test].freeze

  def test_caddy_obtains_distinct_certificates_for_valpo_routes
    skip "set VALPO_PEBBLE_TEST=1 to run the Pebble ACME integration" unless ENV["VALPO_PEBBLE_TEST"] == "1"

    Dir.mktmpdir("valpo-pebble") do
      project = "valpo-pebble-#{Process.pid}"
      caddyfile = File.join(it, "Caddyfile")
      File.write(caddyfile, caddyfile_contents)
      environment = {"VALPO_PEBBLE_CADDYFILE" => caddyfile}

      compose!(environment, project, "up", "--detach", "--quiet-pull")
      port = published_port(environment, project)
      certificates = wait_for_routes(port, environment, project)

      assert_equal HOSTS.sort, certificates.flat_map { it.subject_alt_names }.sort
      refute_equal certificates.fetch(0).serial, certificates.fetch(1).serial
    ensure
      compose(environment, project, "down", "--volumes", "--remove-orphans") if environment && project
    end
  end

  private

  Certificate = Data.define(:serial, :subject_alt_names)

  def caddyfile_contents
    header = <<~CADDYFILE
      {
      \tacme_ca https://pebble:14000/dir
      \tacme_ca_root /test/certs/pebble.minica.pem
      }
    CADDYFILE
    routes = HOSTS.map { {hostname: it, kind: "container", upstream: "app:8080"} }
    "#{header}\n#{Valpo::Caddy::Renderer.new.render(routes)}"
  end

  def compose(environment, project, *arguments)
    Open3.capture3(
      environment,
      "docker", "compose", "--file", COMPOSE_FILE, "--project-name", project,
      *arguments
    )
  end

  def compose!(environment, project, *arguments)
    stdout, stderr, status = compose(environment, project, *arguments)
    return stdout if status.success?

    flunk "docker compose #{arguments.join(" ")} failed:\n#{stdout}\n#{stderr}"
  end

  def published_port(environment, project)
    output = compose!(environment, project, "port", "caddy", "443").strip
    match = output.match(/:(\d+)\z/)
    raise "Cannot parse Caddy port from #{output.inspect}" unless match

    Integer(match[1])
  end

  def wait_for_routes(port, environment, project)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
    last_error = nil

    loop do
      begin
        return HOSTS.map { request(it, port) }
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError => e
        last_error = e
      end

      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.25
    end

    stdout, stderr, = compose(environment, project, "logs", "--no-color")
    flunk "Caddy did not obtain Pebble certificates: #{last_error}\n#{stdout}\n#{stderr}"
  end

  def request(hostname, port)
    tcp = TCPSocket.new("127.0.0.1", port)
    context = OpenSSL::SSL::SSLContext.new
    context.verify_mode = OpenSSL::SSL::VERIFY_NONE
    tls = OpenSSL::SSL::SSLSocket.new(tcp, context)
    tls.hostname = hostname
    tls.connect
    tls.write("GET / HTTP/1.1\r\nHost: #{hostname}\r\nConnection: close\r\n\r\n")
    response = tls.read
    unless response.start_with?("HTTP/1.1 200") && response.end_with?("valpo-pebble-app")
      raise IOError, "unexpected response for #{hostname}"
    end

    certificate = tls.peer_cert
    Certificate.new(serial: certificate.serial, subject_alt_names: subject_alt_names(certificate))
  ensure
    tls&.close
    tcp&.close
  end

  def subject_alt_names(certificate)
    extension = certificate.extensions.find { it.oid == "subjectAltName" }
    extension.to_s.scan(/DNS:([^, ]+)/).flatten
  end
end
