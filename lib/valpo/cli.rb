# frozen_string_literal: true

require "json"
require "net/http"
require "thor"
require "uri"
require "valpo"
require "valpo/api/serializers"

module Valpo
  class CLI < Thor
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

    map "projects:list" => :projects_list
    map "projects:create" => :projects_create
    map "projects:show" => :projects_show
    map "projects:stop" => :projects_stop
    map "projects:restart" => :projects_restart
    map "domains:add" => :domains_add
    map "domains:list" => :domains_list
    map "domains:remove" => :domains_remove
    map "jobs:list" => :jobs_list
    map "jobs:show" => :jobs_show
    map "jobs:events" => :jobs_events
    map "jobs:enqueue-system-check" => :jobs_enqueue_system_check

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

    desc "projects:stop PROJECT", "Stop the active project container"
    def projects_stop(project)
      say_json(request(:post, "/projects/#{project}/stop"))
    end

    desc "projects:restart PROJECT", "Restart the active project container"
    def projects_restart(project)
      say_json(request(:post, "/projects/#{project}/restart"))
    end

    desc "deploy PROJECT", "Deploy a prebuilt Docker image"
    option :image, type: :string, required: true
    option :port, type: :numeric, required: true
    option :healthcheck_path, type: :string
    def deploy(project)
      payload = {
        "image" => options[:image],
        "internal_port" => options[:port],
        "healthcheck_path" => options[:healthcheck_path]
      }.compact
      say_json(request(:post, "/projects/#{project}/deployments", payload))
    end

    desc "releases PROJECT", "List project releases"
    def releases(project)
      say_json(request(:get, "/projects/#{project}/releases"))
    end

    desc "rollback PROJECT", "Roll back to the previous release"
    def rollback(project)
      say_json(request(:post, "/projects/#{project}/rollback"))
    end

    desc "domains:add PROJECT HOSTNAME", "Add a project domain"
    def domains_add(project, hostname)
      say_json(request(:post, "/projects/#{project}/domains", "hostname" => hostname))
    end

    desc "domains:list PROJECT", "List project domains"
    def domains_list(project)
      say_json(request(:get, "/projects/#{project}/domains"))
    end

    desc "domains:remove PROJECT HOSTNAME_OR_ID", "Remove a project domain"
    def domains_remove(project, hostname_or_id)
      say_json(request(:delete, "/projects/#{project}/domains/#{hostname_or_id}"))
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

    private

    def request(method, path, payload = nil)
      uri = URI.join(options[:api_url], path)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      request = request_class(method).new(uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload) if payload

      response = http.request(request)
      parsed = JSON.parse(response.body)
      return parsed if response.code.to_i < 400

      raise Thor::Error, "#{response.code}: #{parsed.fetch("message", response.body)}"
    end

    def request_class(method)
      {
        get: Net::HTTP::Get,
        post: Net::HTTP::Post,
        delete: Net::HTTP::Delete
      }.fetch(method)
    end

    def say_json(value)
      say(JSON.pretty_generate(value))
    end
  end
end
