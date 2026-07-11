# frozen_string_literal: true

require_relative "lib/valpo"

Valpo::Boot.run(config: Valpo::Config.load)

run Valpo::API::App
