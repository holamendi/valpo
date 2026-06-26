# frozen_string_literal: true

require_relative "lib/valpo"

Valpo::Boot.run(config: Valpo::Config.load)

require_relative "lib/valpo/api/app"

run Valpo::API::App
