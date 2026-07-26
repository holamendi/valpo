# frozen_string_literal: true

module Valpo
  module Builds
    Result = Data.define(:image, :strategy, :metadata)
  end
end
