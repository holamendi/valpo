# frozen_string_literal: true

require "rake/testtask"

$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

require "valpo"

STANDARD_ENV = {"RUBOCOP_CACHE_ROOT" => File.join(__dir__, "tmp", "rubocop_cache")}.freeze
PROJECT_STYLE_CONFIG = File.join(__dir__, ".rubocop-project.yml").freeze
PROJECT_STYLE_COMMAND = "bundle exec rubocop --no-server --config #{PROJECT_STYLE_CONFIG}".freeze

namespace :db do
  desc "Run database migrations"
  task :migrate do
    Valpo::Database.connect(Valpo::Config.load)
    Valpo::Migrator.run
  ensure
    Valpo::Database.disconnect
  end
end

namespace :hooks do
  desc "Install repo-managed Git hooks"
  task :install do
    sh "git config core.hooksPath .githooks"
  end
end

namespace :cli do
  desc "Generate the canonical CLI guide"
  task :docs do
    Valpo::CLI::Docs.write
  end

  namespace :docs do
    desc "Verify that the generated CLI guide is current"
    task :check do
      expected = Valpo::CLI::Docs.render
      actual = File.read(Valpo::CLI::Docs::PATH)
      abort "docs/valpo-cli.md is stale; run `rake cli:docs`" unless actual == expected
    end
  end
end

namespace :api do
  desc "Validate OpenAPI structure and route/contract parity"
  task :check do
    sh "bundle exec ruby -Itest test/valpo/api/openapi_test.rb"
  end
end

namespace :docs do
  desc "Validate documentation links"
  task :check do
    sh "bundle exec ruby -Itest test/valpo/documentation_test.rb"
  end
end

desc "Run Standard Ruby and project style policies"
task :standard do
  sh STANDARD_ENV, "bundle exec standardrb"
  sh STANDARD_ENV, PROJECT_STYLE_COMMAND
end

namespace :standard do
  desc "Auto-fix Standard Ruby and project style offenses"
  task :fix do
    sh STANDARD_ENV, "#{PROJECT_STYLE_COMMAND} --autocorrect"
    sh STANDARD_ENV, "bundle exec standardrb --fix"
  end
end

namespace :test do
  desc "Run the opt-in Caddy ACME integration against Pebble"
  task :pebble do
    sh({"VALPO_PEBBLE_TEST" => "1"}, "bundle exec ruby -Itest test/integration/caddy_pebble_test.rb")
  end
end

Rake::TestTask.new(:test) do
  it.libs << "test"
  it.pattern = "test/**/*_test.rb"
end

task default: :test
