# frozen_string_literal: true

require "json"
require "thor"
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

    class_option :api_url,
      type: :string,
      default: ENV.fetch("VALPO_API_URL", "http://127.0.0.1:7092"),
      desc: "Valpo API URL"
    class_option :config,
      type: :string,
      default: ENV["VALPO_CONFIG"],
      desc: "Path to valpo.yml"
    class_option :api_token,
      type: :string,
      default: ENV["VALPO_API_TOKEN"],
      desc: "Bearer token for Valpo API"

    map "projects:list" => :projects_list
    map "projects:create" => :projects_create
    map "projects:show" => :projects_show
    map "projects:delete" => :projects_delete
    map "projects:stop" => :projects_stop
    map "projects:restart" => :projects_restart
    map "domains:add" => :domains_add
    map "domains:list" => :domains_list
    map "domains:remove" => :domains_remove
    map "jobs:list" => :jobs_list
    map "jobs:show" => :jobs_show
    map "jobs:wait" => :jobs_wait
    map "jobs:events" => :jobs_events
    map "jobs:enqueue-system-check" => :jobs_enqueue_system_check
    map "system:repair" => :system_repair

    desc "projects:list", "List projects"
    def projects_list
      say_json(request(:get, "/projects"))
    end

    desc "projects:create NAME", "Create a project"
    option :type, type: :string, default: "container"
    def projects_create(name)
      say_json(request(:post, "/projects", "name" => name, "type" => options[:type]))
    end

    desc "projects:show ID_OR_NAME", "Show a project"
    def projects_show(id_or_name)
      say_json(request(:get, "/projects/#{id_or_name}"))
    end

    desc "projects:delete PROJECT", "Delete a project and clean up runtime state"
    option :wait, type: :boolean, default: false, desc: "Wait for the delete job to finish"
    option :wait_timeout, type: :numeric, default: DEFAULT_WAIT_TIMEOUT, desc: "Seconds to wait for job completion"
    option :wait_interval, type: :numeric, default: DEFAULT_WAIT_INTERVAL, desc: "Seconds between job status polls"
    def projects_delete(project)
      say_json(maybe_wait_job(request(:delete, "/projects/#{project}")))
    end

    desc "projects:stop PROJECT", "Stop the active project container"
    option :wait, type: :boolean, default: false, desc: "Wait for the stop job to finish"
    option :wait_timeout, type: :numeric, default: DEFAULT_WAIT_TIMEOUT, desc: "Seconds to wait for job completion"
    option :wait_interval, type: :numeric, default: DEFAULT_WAIT_INTERVAL, desc: "Seconds between job status polls"
    def projects_stop(project)
      say_json(maybe_wait_job(request(:post, "/projects/#{project}/stop")))
    end

    desc "projects:restart PROJECT", "Restart the active project container"
    option :wait, type: :boolean, default: false, desc: "Wait for the restart job to finish"
    option :wait_timeout, type: :numeric, default: DEFAULT_WAIT_TIMEOUT, desc: "Seconds to wait for job completion"
    option :wait_interval, type: :numeric, default: DEFAULT_WAIT_INTERVAL, desc: "Seconds between job status polls"
    def projects_restart(project)
      say_json(maybe_wait_job(request(:post, "/projects/#{project}/restart")))
    end

    desc "deploy PROJECT", "Deploy a prebuilt Docker image"
    option :image, type: :string, required: true
    option :port, type: :numeric, required: true
    option :healthcheck_path, type: :string
    option :wait, type: :boolean, default: false, desc: "Wait for the deploy job to finish"
    option :wait_timeout, type: :numeric, default: DEFAULT_WAIT_TIMEOUT, desc: "Seconds to wait for job completion"
    option :wait_interval, type: :numeric, default: DEFAULT_WAIT_INTERVAL, desc: "Seconds between job status polls"
    def deploy(project)
      payload = {
        "image" => options[:image],
        "internal_port" => options[:port],
        "healthcheck_path" => options[:healthcheck_path]
      }.compact
      say_json(maybe_wait_job(request(:post, "/projects/#{project}/deployments", payload)))
    end

    desc "releases PROJECT", "List project releases"
    def releases(project)
      say_json(request(:get, "/projects/#{project}/releases"))
    end

    desc "rollback PROJECT", "Roll back to the previous release"
    option :wait, type: :boolean, default: false, desc: "Wait for the rollback job to finish"
    option :wait_timeout, type: :numeric, default: DEFAULT_WAIT_TIMEOUT, desc: "Seconds to wait for job completion"
    option :wait_interval, type: :numeric, default: DEFAULT_WAIT_INTERVAL, desc: "Seconds between job status polls"
    def rollback(project)
      say_json(maybe_wait_job(request(:post, "/projects/#{project}/rollback")))
    end

    desc "domains:add PROJECT HOSTNAME", "Add a project domain"
    option :wait, type: :boolean, default: false, desc: "Wait for the Caddy apply job to finish"
    option :wait_timeout, type: :numeric, default: DEFAULT_WAIT_TIMEOUT, desc: "Seconds to wait for job completion"
    option :wait_interval, type: :numeric, default: DEFAULT_WAIT_INTERVAL, desc: "Seconds between job status polls"
    def domains_add(project, hostname)
      say_json(maybe_wait_response_job(request(:post, "/projects/#{project}/domains", "hostname" => hostname)))
    end

    desc "domains:list PROJECT", "List project domains"
    def domains_list(project)
      say_json(request(:get, "/projects/#{project}/domains"))
    end

    desc "domains:remove PROJECT HOSTNAME_OR_ID", "Remove a project domain"
    option :wait, type: :boolean, default: false, desc: "Wait for the Caddy apply job to finish"
    option :wait_timeout, type: :numeric, default: DEFAULT_WAIT_TIMEOUT, desc: "Seconds to wait for job completion"
    option :wait_interval, type: :numeric, default: DEFAULT_WAIT_INTERVAL, desc: "Seconds between job status polls"
    def domains_remove(project, hostname_or_id)
      say_json(maybe_wait_response_job(request(:delete, "/projects/#{project}/domains/#{hostname_or_id}")))
    end

    desc "logs PROJECT", "Print active app container logs"
    option :tail, type: :numeric
    def logs(project)
      path = "/projects/#{project}/logs"
      path = "#{path}?tail=#{options[:tail]}" if options[:tail]
      payload = request(:get, path)
      say payload.fetch("stdout")
      warn payload.fetch("stderr") unless payload.fetch("stderr").to_s.empty?
    end

    desc "jobs:list", "List jobs"
    def jobs_list
      say_json(request(:get, "/jobs"))
    end

    desc "jobs:show ID", "Show a job"
    def jobs_show(id)
      say_json(request(:get, "/jobs/#{id}"))
    end

    desc "jobs:wait ID", "Wait for a job to finish"
    option :timeout, type: :numeric, default: DEFAULT_WAIT_TIMEOUT, desc: "Seconds to wait for job completion"
    option :interval, type: :numeric, default: DEFAULT_WAIT_INTERVAL, desc: "Seconds between job status polls"
    def jobs_wait(id)
      say_json(wait_for_job(id, timeout: options[:timeout], interval: options[:interval]))
    end

    desc "jobs:events ID", "Show job events"
    def jobs_events(id)
      say_json(request(:get, "/jobs/#{id}/events"))
    end

    desc "jobs:enqueue-system-check", "Enqueue a local system_check job"
    def jobs_enqueue_system_check
      config = Valpo::Config.load(path: options[:config])
      Valpo::Boot.run(config: config)
      require "valpo/jobs/queue"
      job = Valpo::Jobs::Queue.new.enqueue("system_check", source: "cli")
      say_json(Valpo::API::Serializers.job(job))
    ensure
      Valpo::Database.disconnect
    end

    desc "system:repair", "Regenerate runtime config from Valpo state"
    option :wait, type: :boolean, default: false, desc: "Wait for the repair job to finish"
    option :wait_timeout, type: :numeric, default: DEFAULT_WAIT_TIMEOUT, desc: "Seconds to wait for job completion"
    option :wait_interval, type: :numeric, default: DEFAULT_WAIT_INTERVAL, desc: "Seconds between job status polls"
    def system_repair
      say_json(maybe_wait_job(request(:post, "/system/repair")))
    end

    private

    def maybe_wait_job(job)
      return job unless options[:wait]

      wait_for_job(
        job.fetch("id"),
        timeout: options[:wait_timeout],
        interval: options[:wait_interval]
      )
    end

    def maybe_wait_response_job(response)
      return response unless options[:wait]

      response.merge(
        "job" => wait_for_job(
          response.fetch("job").fetch("id"),
          timeout: options[:wait_timeout],
          interval: options[:wait_interval]
        )
      )
    end

    def wait_for_job(id, timeout:, interval:)
      timeout = positive_number(timeout, "timeout")
      interval = positive_number(interval, "interval")
      deadline = monotonic_now + timeout

      loop do
        job = request(:get, "/jobs/#{id}")
        case job.fetch("status")
        when "succeeded"
          return job
        when "failed"
          error = job["error"].to_s
          detail = error.empty? ? "" : ": #{error}"
          raise Thor::Error, "Job #{id} failed#{detail}"
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
      @api_client ||= Valpo::API::Client.new(
        base_url: options[:api_url],
        api_token: options[:api_token],
        config_path: options[:config]
      )
    end

    def say_json(value)
      say(JSON.pretty_generate(value))
    end
  end
end
