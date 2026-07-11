# frozen_string_literal: true

require "json"
require "thor"
require "uri"
require "valpo"
require "valpo/api/client"
require "valpo/api/serializers"

module Valpo
  class CLI < Thor
    DEFAULT_WAIT_INTERVAL = 2
    DEFAULT_WAIT_TIMEOUT = 600

    def self.exit_on_failure?
      true
    end

    def self.wait_options(operation)
      option :wait, type: :boolean, default: false, desc: "Wait for #{operation} to finish"
      option :wait_timeout, type: :numeric, default: DEFAULT_WAIT_TIMEOUT
      option :wait_interval, type: :numeric, default: DEFAULT_WAIT_INTERVAL
    end

    class_option :api_url, type: :string, default: ENV.fetch("VALPO_API_URL", "http://127.0.0.1:7092"), desc: "Valpo API URL"
    class_option :config, type: :string, default: ENV["VALPO_CONFIG"], desc: "Path to the Valpo server configuration"
    class_option :api_token, type: :string, default: ENV["VALPO_API_TOKEN"], desc: "Bearer token for Valpo API"

    %w[list create show delete apply logs].each { |name| map "projects:#{name}" => :"projects_#{name}" }
    %w[list create show delete restart stop bind unbind logs].each { |name| map "services:#{name}" => :"services_#{name}" }
    %w[add list remove].each { |name| map "domains:#{name}" => :"domains_#{name}" }
    %w[list show wait events].each { |name| map "jobs:#{name}" => :"jobs_#{name}" }
    map "jobs:enqueue-system-check" => :jobs_enqueue_system_check
    map "system:repair" => :system_repair

    desc "projects:list", "List projects"
    def projects_list
      say_json(request(:get, "/projects"))
    end

    desc "projects:create NAME", "Create a project"
    def projects_create(name)
      say_json(request(:post, "/projects", "name" => name))
    end

    desc "projects:show PROJECT", "Show a project"
    def projects_show(project)
      say_json(request(:get, "/projects/#{segment(project)}"))
    end

    desc "projects:delete PROJECT", "Delete an empty project"
    wait_options("delete")
    def projects_delete(project)
      say_json(maybe_wait_job(request(:delete, "/projects/#{segment(project)}")))
    end

    desc "projects:apply FILE", "Reconcile a project from valpo.toml"
    option :dry_run, type: :boolean, default: false, desc: "Preview changes without applying them"
    wait_options("reconciliation")
    def projects_apply(file)
      manifest = File.read(file)
      result = request(:post, "/projects/apply", "manifest" => manifest, "dry_run" => options[:dry_run])
      say_json(options[:dry_run] ? result : maybe_wait_job(result))
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Thor::Error, "Cannot read #{file}: #{e.message}"
    end

    desc "projects:logs PROJECT", "Print logs for all project services"
    option :service, type: :string, desc: "Only show one service name"
    option :tail, type: :numeric
    def projects_logs(project)
      query = {"service" => options[:service], "tail" => options[:tail]}.compact
      path = "/projects/#{segment(project)}/logs"
      path = "#{path}?#{URI.encode_www_form(query)}" unless query.empty?
      payload = request(:get, path)
      payload.fetch("logs").each do |entry|
        prefix = "[#{entry.fetch("service_name")}]"
        if entry["error"]
          warn "#{prefix} #{entry.fetch("error")}"
        else
          entry.fetch("stdout").each_line { |line| say "#{prefix} #{line.chomp}" }
          entry.fetch("stderr").each_line { |line| warn "#{prefix} #{line.chomp}" }
        end
      end
    end

    desc "services:create PROJECT/NAME", "Create an app or managed service"
    option :type, type: :string, required: true
    option :version, type: :string
    option :command, type: :array
    option :port, type: :numeric
    option :healthcheck_path, type: :string
    wait_options("provisioning")
    def services_create(reference)
      project, name = split_new_service_reference(reference)
      payload = {
        "name" => name, "type" => options[:type], "version" => options[:version],
        "command" => options[:command], "internal_port" => options[:port], "healthcheck_path" => options[:healthcheck_path]
      }.compact
      response = request(:post, "/projects/#{segment(project)}/services", payload)
      say_json(maybe_wait_response_job(response))
    end

    desc "services:list [PROJECT]", "List services"
    def services_list(project = nil)
      path = "/services"
      path = "#{path}?#{URI.encode_www_form("project" => project)}" if project
      say_json(request(:get, path))
    end

    desc "services:show SERVICE", "Show a service"
    def services_show(service)
      say_json(request(:get, service_path(service)))
    end

    desc "services:restart SERVICE", "Restart a service"
    wait_options("restart")
    def services_restart(service)
      say_json(maybe_wait_job(request(:post, "#{service_path(service)}/restart")))
    end

    desc "services:stop SERVICE", "Stop a service"
    wait_options("stop")
    def services_stop(service)
      say_json(maybe_wait_job(request(:post, "#{service_path(service)}/stop")))
    end

    desc "services:bind APP_SERVICE MANAGED_SERVICE", "Bind a managed dependency to an app service"
    wait_options("bind")
    def services_bind(app_service, managed_service)
      app_id = resolve_service_id(app_service)
      managed_id = resolve_service_id(managed_service)
      say_json(maybe_wait_job(request(:post, "/services/#{app_id}/dependencies", "dependency_service_id" => managed_id)))
    end

    desc "services:unbind APP_SERVICE MANAGED_SERVICE", "Remove a managed dependency from an app service"
    wait_options("unbind")
    def services_unbind(app_service, managed_service)
      app_id = resolve_service_id(app_service)
      managed_id = resolve_service_id(managed_service)
      say_json(maybe_wait_job(request(:delete, "/services/#{app_id}/dependencies/#{managed_id}")))
    end

    desc "services:delete SERVICE", "Delete a service and its runtime state"
    option :force, type: :boolean, default: false, desc: "Required to delete a service"
    wait_options("delete")
    def services_delete(service)
      raise Thor::Error, "--force is required to delete a service" unless options[:force]
      say_json(maybe_wait_job(request(:delete, "#{service_path(service)}?force=true")))
    end

    desc "logs SERVICE", "Print service container logs"
    option :tail, type: :numeric
    def logs(service)
      path = "#{service_path(service)}/logs"
      path = "#{path}?tail=#{options[:tail]}" if options[:tail]
      payload = request(:get, path)
      say payload.fetch("stdout")
      warn payload.fetch("stderr") unless payload.fetch("stderr").to_s.empty?
    end

    desc "services:logs SERVICE", "Print service container logs"
    option :tail, type: :numeric
    def services_logs(service)
      logs(service)
    end

    desc "deploy SERVICE", "Deploy a prebuilt Docker image to an app service"
    option :image, type: :string, required: true
    option :port, type: :numeric
    option :healthcheck_path, type: :string
    wait_options("deploy")
    def deploy(service)
      payload = {"image" => options[:image], "internal_port" => options[:port], "healthcheck_path" => options[:healthcheck_path]}.compact
      say_json(maybe_wait_job(request(:post, "#{service_path(service)}/deployments", payload)))
    end

    desc "releases SERVICE", "List app-service releases"
    def releases(service)
      say_json(request(:get, "#{service_path(service)}/releases"))
    end

    desc "rollback SERVICE", "Roll back an app service"
    wait_options("rollback")
    def rollback(service)
      say_json(maybe_wait_job(request(:post, "#{service_path(service)}/rollback")))
    end

    desc "domains:add SERVICE HOSTNAME", "Add a domain to a web service"
    wait_options("Caddy apply")
    def domains_add(service, hostname)
      say_json(maybe_wait_response_job(request(:post, "#{service_path(service)}/domains", "hostname" => hostname)))
    end

    desc "domains:list SERVICE", "List web-service domains"
    def domains_list(service)
      say_json(request(:get, "#{service_path(service)}/domains"))
    end

    desc "domains:remove SERVICE HOSTNAME_OR_ID", "Remove a web-service domain"
    wait_options("Caddy apply")
    def domains_remove(service, domain)
      say_json(maybe_wait_response_job(request(:delete, "#{service_path(service)}/domains/#{segment(domain)}")))
    end

    desc "env SERVICE", "Show managed environment variables for an app service"
    option :reveal, type: :boolean, default: false, desc: "Reveal secret values"
    def env(service)
      path = "#{service_path(service)}/env"
      path = "#{path}?reveal=true" if options[:reveal]
      say_json(request(:get, path))
    end

    desc "jobs:list", "List jobs"
    def jobs_list
      say_json(request(:get, "/jobs"))
    end

    desc "jobs:show ID", "Show a job"
    def jobs_show(id)
      say_json(request(:get, "/jobs/#{segment(id)}"))
    end

    desc "jobs:wait ID", "Wait for a job to finish"
    option :timeout, type: :numeric, default: DEFAULT_WAIT_TIMEOUT
    option :interval, type: :numeric, default: DEFAULT_WAIT_INTERVAL
    def jobs_wait(id)
      say_json(wait_for_job(id, timeout: options[:timeout], interval: options[:interval]))
    end

    desc "jobs:events ID", "Show job events"
    def jobs_events(id)
      say_json(request(:get, "/jobs/#{segment(id)}/events"))
    end

    desc "jobs:enqueue-system-check", "Enqueue a local system_check job"
    def jobs_enqueue_system_check
      config = Valpo::Config.load(path: options[:config])
      Valpo::Boot.run(config: config)
      require "valpo/jobs/queue"
      say_json(Valpo::API::Serializers.job(Valpo::Jobs::Queue.new.enqueue("system_check", source: "cli")))
    ensure
      Valpo::Database.disconnect
    end

    desc "system:repair", "Regenerate runtime config from Valpo state"
    wait_options("repair")
    def system_repair
      say_json(maybe_wait_job(request(:post, "/system/repair")))
    end

    private

    def split_new_service_reference(reference)
      parts = reference.to_s.split("/")
      raise Thor::Error, "Service name must be PROJECT/NAME" unless parts.length == 2 && parts.none?(&:empty?)
      parts
    end

    def resolve_service_id(reference)
      if reference.to_s.start_with?("svc_")
        raise Thor::Error, "Invalid service ID: #{reference}" unless reference.to_s.match?(/\Asvc_[0-9a-f]{32}\z/)
        return reference
      end
      project, name = split_new_service_reference(reference)
      services = request(:get, "/projects/#{segment(project)}/services")
      service = services.find { |entry| entry.fetch("name") == name }
      raise Thor::Error, "Service not found: #{reference}" unless service
      service.fetch("id")
    end

    def service_path(reference)
      "/services/#{resolve_service_id(reference)}"
    end

    def segment(value)
      URI.encode_www_form_component(value.to_s)
    end

    def maybe_wait_job(job)
      return job unless options[:wait]
      wait_for_job(job.fetch("id"), timeout: options[:wait_timeout], interval: options[:wait_interval])
    end

    def maybe_wait_response_job(response)
      return response unless options[:wait]
      job = response["job"]
      return response unless job
      response.merge("job" => wait_for_job(job.fetch("id"), timeout: options[:wait_timeout], interval: options[:wait_interval]))
    end

    def wait_for_job(id, timeout:, interval:)
      timeout = positive_number(timeout, "timeout")
      interval = positive_number(interval, "interval")
      deadline = monotonic_now + timeout
      loop do
        job = request(:get, "/jobs/#{id}")
        return job if job.fetch("status") == "succeeded"
        if job.fetch("status") == "failed"
          detail = job["error"].to_s
          raise Thor::Error, ["Job #{id} failed", detail].reject(&:empty?).join(": ")
        end
        remaining = deadline - monotonic_now
        raise Thor::Error, "Timed out waiting for job #{id}" unless remaining.positive?
        sleep [interval, remaining].min
      end
    end

    def positive_number(value, name)
      number = Float(value)
      raise Thor::Error, "#{name} must be greater than 0" unless number.positive?
      number
    rescue ArgumentError, TypeError
      raise Thor::Error, "#{name} must be a number"
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def request(method, path, payload = nil)
      api_client.request(method, path, payload)
    rescue Valpo::API::Client::Error => e
      raise Thor::Error, e.message
    end

    def api_client
      @api_client ||= Valpo::API::Client.new(base_url: options[:api_url], api_token: options[:api_token], config_path: options[:config])
    end

    def say_json(value)
      say(JSON.pretty_generate(value))
    end
  end
end
