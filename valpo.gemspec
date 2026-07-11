# frozen_string_literal: true

require_relative "lib/valpo/version"

Gem::Specification.new do |spec|
  spec.name = "valpo"
  spec.version = Valpo::VERSION
  spec.summary = "A lightweight VPS application platform control plane."
  spec.description = "Valpo is an early-stage, single-server application platform scaffold."
  spec.authors = ["Valpo contributors"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/holamendi/valpo"
  spec.required_ruby_version = "= 4.0.5"
  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "#{spec.homepage}/tree/main"
  }

  spec.files = Dir[
    "lib/**/*.rb",
    "db/migrations/*.rb",
    "exe/*",
    "packaging/**/*",
    "docs/**/*.md",
    "README.md",
    "LICENSE"
  ]
  spec.bindir = "exe"
  spec.executables = ["valpo", "valpo-api", "valpo-worker"]
  spec.require_paths = ["lib"]

  spec.add_dependency "json", ">= 2.7", "< 3"
  spec.add_dependency "puma", ">= 6.5", "< 8"
  spec.add_dependency "rack", ">= 3.1", "< 4"
  spec.add_dependency "rackup", ">= 2.2", "< 3"
  spec.add_dependency "roda", ">= 3.80", "< 4"
  spec.add_dependency "sequel", ">= 5.90", "< 6"
  spec.add_dependency "sqlite3", ">= 2.0", "< 3"
  spec.add_dependency "thor", ">= 1.3", "< 2"
  spec.add_dependency "toml-rb", ">= 4.2", "< 5"
  spec.add_dependency "zeitwerk", ">= 2.7", "< 3"

  spec.add_development_dependency "minitest", ">= 5.25", "< 6"
  spec.add_development_dependency "rack-test", ">= 2.1", "< 3"
  spec.add_development_dependency "rake", ">= 13.2", "< 14"
  spec.add_development_dependency "standard", ">= 1.42", "< 2"
end
