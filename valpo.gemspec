# frozen_string_literal: true

require_relative "lib/valpo/version"

Gem::Specification.new do
  it.name = "valpo"
  it.version = Valpo::VERSION
  it.summary = "A lightweight VPS application platform control plane."
  it.description = "Valpo is an early-stage, single-server application platform scaffold."
  it.authors = ["Valpo contributors"]
  it.license = "MIT"
  it.homepage = "https://github.com/holamendi/valpo"
  it.required_ruby_version = "= 4.0.5"
  it.metadata = {
    "homepage_uri" => it.homepage,
    "source_code_uri" => "#{it.homepage}/tree/main"
  }

  it.files = Dir[
    "lib/**/*.rb",
    "db/migrations/*.rb",
    "exe/*",
    "packaging/**/*",
    "docs/**/*.md",
    "docs/**/*.yaml",
    "README.md",
    "LICENSE"
  ]
  it.bindir = "exe"
  it.executables = ["valpo", "valpo-api", "valpo-worker"]
  it.require_paths = ["lib"]

  it.add_dependency "json", ">= 2.7", "< 3"
  it.add_dependency "dry-cli", ">= 1.4", "< 2"
  it.add_dependency "dry-validation", "~> 1.11"
  it.add_dependency "puma", ">= 6.5", "< 8"
  it.add_dependency "rack", ">= 3.1", "< 4"
  it.add_dependency "rackup", ">= 2.2", "< 3"
  it.add_dependency "roda", ">= 3.80", "< 4"
  it.add_dependency "sequel", ">= 5.90", "< 6"
  it.add_dependency "sqlite3", ">= 2.0", "< 3"
  it.add_dependency "toml-rb", ">= 4.2", "< 5"
  it.add_dependency "zeitwerk", ">= 2.7", "< 3"

  it.add_development_dependency "minitest", ">= 5.25", "< 6"
  it.add_development_dependency "rack-test", ">= 2.1", "< 3"
  it.add_development_dependency "rake", ">= 13.2", "< 14"
  it.add_development_dependency "standard", ">= 1.42", "< 2"
end
