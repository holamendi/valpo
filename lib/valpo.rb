# frozen_string_literal: true

require "zeitwerk"
require_relative "valpo/version"

module Valpo
  class << self
    attr_accessor :config, :secrets
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
        File.join(__dir__, "valpo", "api", "routes")
      )
      loader.inflector.inflect(
        "api" => "API",
        "api_credential" => "APICredential",
        "api_credentials" => "APICredentials",
        "cli" => "CLI",
        "github" => "GitHub",
        "github_app_setup" => "GitHubAppSetup",
        "github_webhook_delivery" => "GitHubWebhookDelivery"
      )
      loader.setup
      loader
    end
  end
end

Valpo.loader
