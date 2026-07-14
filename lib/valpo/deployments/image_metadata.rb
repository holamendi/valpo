# frozen_string_literal: true

module Valpo
  module Deployments
    ImageMetadata = Data.define(:digest, :exposed_tcp_ports)
  end
end
