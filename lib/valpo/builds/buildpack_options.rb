# frozen_string_literal: true

module Valpo
  module Builds
    module BuildpackOptions
      # Remote OCI references and builder-contained buildpack IDs only. Never
      # accept host filesystem paths or Dockerfile instructions as references.
      REFERENCE = %r{\A[a-zA-Z0-9][a-zA-Z0-9._:/@+-]*\z}

      def self.validate!(strategy:, builder:, buildpacks:)
        if strategy == "dockerfile" && (builder || buildpacks)
          raise Valpo::ValidationError, "builder and buildpacks are only valid for auto or buildpack builds"
        end
        if builder && (!builder.is_a?(String) || !builder.match?(REFERENCE) || builder.include?("://"))
          raise Valpo::ValidationError, "builder must be an OCI image reference"
        end
        return if buildpacks.nil?

        unless buildpacks.is_a?(Array) && !buildpacks.empty? && buildpacks.all? { it.is_a?(String) && it.match?(REFERENCE) && !it.include?("://") }
          raise Valpo::ValidationError, "buildpacks must be a non-empty ordered array of buildpack IDs or OCI image references"
        end
        raise Valpo::ValidationError, "buildpacks must not contain duplicates" unless buildpacks.uniq == buildpacks
      end
    end
  end
end
