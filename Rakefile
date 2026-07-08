# frozen_string_literal: true

require "rake/testtask"

$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

require "valpo"

STANDARD_ENV = {"RUBOCOP_CACHE_ROOT" => File.join(__dir__, "tmp", "rubocop_cache")}.freeze

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

desc "Run Standard Ruby"
task :standard do
  sh STANDARD_ENV, "bundle exec standardrb"
end

namespace :standard do
  desc "Auto-fix Standard Ruby offenses"
  task :fix do
    sh STANDARD_ENV, "bundle exec standardrb --fix"
  end
end

Rake::TestTask.new(:test) do |test|
  test.libs << "test"
  test.pattern = "test/**/*_test.rb"
end

task default: :test
