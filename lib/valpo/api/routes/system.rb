# frozen_string_literal: true

module Valpo
  module API
    class App
      hash_branch("", "system") do |r|
        r.on "repair" do
          r.post do
            response.status = 202
            Serializers.job(jobs.enqueue("repair_system"))
          end
        end
      end
    end
  end
end
