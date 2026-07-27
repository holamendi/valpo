# frozen_string_literal: true

module Valpo
  module Jobs
    module Handlers
      class MaintainStorage
        def initialize(maintainer:)
          @maintainer = maintainer
        end

        def call(job, queue:)
          maintainer.call(
            dry_run: job.payload.fetch("dry_run", false),
            queue:,
            job_id: job.id
          )
        end

        private

        attr_reader :maintainer
      end
    end
  end
end
