# frozen_string_literal: true

module Valpo
  module CLI
    module Registry
      extend Dry::CLI::Registry

      GROUPS = {
        "auth" => "Manage source-provider authentication",
        "project" => "Manage projects",
        "service" => "Manage app and managed services",
        "domain" => "Manage web-service domains",
        "release" => "Inspect and roll back releases",
        "system" => "Inspect and repair the Valpo host",
        "job" => "Inspect background jobs"
      }.freeze

      COMMANDS = [
        ["auth login", Commands::Auth::Login, false],
        ["auth status", Commands::Auth::Status, false],
        ["auth logout", Commands::Auth::Logout, false],
        ["project list", Commands::Project::List, false],
        ["project create", Commands::Project::Create, false],
        ["project show", Commands::Project::Show, false],
        ["project delete", Commands::Project::Delete, false],
        ["project apply", Commands::Project::Apply, false],
        ["project logs", Commands::Project::Logs, false],
        ["service list", Commands::Service::List, false],
        ["service create", Commands::Service::Create, false],
        ["service show", Commands::Service::Show, false],
        ["service update", Commands::Service::Update, false],
        ["service delete", Commands::Service::Delete, false],
        ["service deploy", Commands::Service::Deploy, false],
        ["service logs", Commands::Service::Logs, false],
        ["service restart", Commands::Service::Restart, false],
        ["service stop", Commands::Service::Stop, false],
        ["service env", Commands::Service::Env, false],
        ["service bind", Commands::Service::Bind, false],
        ["service unbind", Commands::Service::Unbind, false],
        ["domain list", Commands::Domain::List, false],
        ["domain add", Commands::Domain::Add, false],
        ["domain remove", Commands::Domain::Remove, false],
        ["release list", Commands::Release::List, false],
        ["release rollback", Commands::Release::Rollback, false],
        ["system status", Commands::System::Status, false],
        ["system repair", Commands::System::Repair, false],
        ["job list", Commands::Job::List, true],
        ["job show", Commands::Job::Show, true],
        ["job wait", Commands::Job::Wait, true],
        ["job events", Commands::Job::Events, true],
        ["version", Commands::Version, false]
      ].freeze

      register "auth" do |prefix|
        prefix.register "login", Commands::Auth::Login
        prefix.register "status", Commands::Auth::Status
        prefix.register "logout", Commands::Auth::Logout
      end

      register "project" do |prefix|
        prefix.register "list", Commands::Project::List
        prefix.register "create", Commands::Project::Create
        prefix.register "show", Commands::Project::Show
        prefix.register "delete", Commands::Project::Delete
        prefix.register "apply", Commands::Project::Apply
        prefix.register "logs", Commands::Project::Logs
      end

      register "service" do |prefix|
        prefix.register "list", Commands::Service::List
        prefix.register "create", Commands::Service::Create
        prefix.register "show", Commands::Service::Show
        prefix.register "update", Commands::Service::Update
        prefix.register "delete", Commands::Service::Delete
        prefix.register "deploy", Commands::Service::Deploy
        prefix.register "logs", Commands::Service::Logs
        prefix.register "restart", Commands::Service::Restart
        prefix.register "stop", Commands::Service::Stop
        prefix.register "env", Commands::Service::Env
        prefix.register "bind", Commands::Service::Bind
        prefix.register "unbind", Commands::Service::Unbind
      end

      register "domain" do |prefix|
        prefix.register "list", Commands::Domain::List
        prefix.register "add", Commands::Domain::Add
        prefix.register "remove", Commands::Domain::Remove
      end

      register "release" do |prefix|
        prefix.register "list", Commands::Release::List
        prefix.register "rollback", Commands::Release::Rollback
      end

      register "system" do |prefix|
        prefix.register "status", Commands::System::Status
        prefix.register "repair", Commands::System::Repair
      end

      register "job", hidden: true do |prefix|
        prefix.register "list", Commands::Job::List
        prefix.register "show", Commands::Job::Show
        prefix.register "wait", Commands::Job::Wait
        prefix.register "events", Commands::Job::Events
      end

      register "version", Commands::Version
    end
  end
end
