# frozen_string_literal: true

module Valpo
  def self.root
    File.expand_path("..", __dir__)
  end
end

require "valpo/version"
require "valpo/errors"
require "valpo/config"
require "valpo/database"
require "valpo/migrator"
require "valpo/boot"
