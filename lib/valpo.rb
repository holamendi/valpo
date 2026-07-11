# frozen_string_literal: true

module Valpo
  class << self
    attr_accessor :config
  end

  def self.root
    File.expand_path("..", __dir__)
  end
end

require "valpo/version"
require "valpo/errors"
require "valpo/identifier"
require "valpo/config"
require "valpo/database"
require "valpo/migrator"
require "valpo/boot"
