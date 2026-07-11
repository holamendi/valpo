# frozen_string_literal: true

require "zeitwerk"
require_relative "valpo/version"
require_relative "valpo/errors"

module Valpo
  class << self
    attr_accessor :config
  end

  def self.root
    File.expand_path("..", __dir__)
  end

  def self.loader
    @loader ||= begin
      loader = Zeitwerk::Loader.new
      loader.tag = "valpo"
      loader.push_dir(File.join(__dir__, "valpo"), namespace: self)
      loader.collapse(File.join(__dir__, "valpo", "models"))
      loader.ignore(
        File.join(__dir__, "valpo", "version.rb"),
        File.join(__dir__, "valpo", "errors.rb")
      )
      loader.inflector.inflect("api" => "API", "cli" => "CLI")
      loader.setup
      loader
    end
  end
end

Valpo.loader
