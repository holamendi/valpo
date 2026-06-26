# frozen_string_literal: true

require "rake/testtask"

$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

require "valpo"

namespace :db do
  desc "Run database migrations"
  task :migrate do
    Valpo::Database.connect(Valpo::Config.load)
    Valpo::Migrator.run
  ensure
    Valpo::Database.disconnect
  end
end

Rake::TestTask.new(:test) do |test|
  test.libs << "test"
  test.pattern = "test/**/*_test.rb"
end

task default: :test
