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
        ["auth token list", Commands::Auth::Token::List, false],
        ["auth token create", Commands::Auth::Token::Create, false],
        ["auth token revoke", Commands::Auth::Token::Revoke, false],
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
        ["service env list", Commands::Service::Env::List, false],
        ["service env set", Commands::Service::Env::Set, false],
        ["service env unset", Commands::Service::Env::Unset, false],
        ["service env reconcile", Commands::Service::Env::Reconcile, false],
        ["service bind", Commands::Service::Bind, false],
        ["service unbind", Commands::Service::Unbind, false],
        ["domain show-default", Commands::Domain::ShowDefault, false],
        ["domain set-default", Commands::Domain::SetDefault, false],
        ["domain list", Commands::Domain::List, false],
        ["domain add", Commands::Domain::Add, false],
        ["domain verify", Commands::Domain::Verify, false],
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

      grouped = COMMANDS.group_by { |path, _command, _hidden| path.split.first }
      grouped.each do |group, definitions|
        if definitions.length == 1 && definitions.first.first == group
          register group, definitions.first[1]
          next
        end

        options = (definitions.all? { |_path, _command, hidden| hidden }) ? {hidden: true} : {}
        register group, **options do
          group_registry = it
          definitions.each do |path, command, _hidden|
            group_registry.register path.split.drop(1).join(" "), command
          end
        end
      end
    end
  end
end
