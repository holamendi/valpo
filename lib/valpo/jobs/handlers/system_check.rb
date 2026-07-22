# frozen_string_literal: true

module Valpo
  module Jobs
    module Handlers
      class SystemCheck
        def call(job, queue:)
          queue.event(job[:id], "stdout", "Valpo worker executed system_check")
        end
      end
    end
  end
end
