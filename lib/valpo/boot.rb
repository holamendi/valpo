# frozen_string_literal: true

module Valpo
  module Boot
    def self.run(config: Valpo::Config.load, migrate: false)
      Valpo::Database.connect(config)
      Valpo::Migrator.run if migrate
      require "valpo/models/project"
      require "valpo/models/job"
      require "valpo/models/job_event"
      Valpo::Database.connection
    end
  end
end
