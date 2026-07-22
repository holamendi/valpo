# frozen_string_literal: true

require "tmpdir"

module Valpo
  module Sources
    class Preflight
      COMMIT_PATTERN = /\A[0-9a-f]{40,64}\z/i
      Candidate = Data.define(:provider, :repository, :ref)
      Result = Data.define(:checkout, :dockerfile, :context, :commit, :ref)

      def initialize(fetcher:)
        @fetcher = fetcher
      end

      def with_checkout(provider:, repository:, ref: "HEAD", dockerfile: "Dockerfile", context: ".")
        selected_ref = blank_to_default(ref, "HEAD")
        source = Candidate.new(provider:, repository:, ref: selected_ref)

        Dir.mktmpdir("valpo-source-") do
          checkout = it
          commit = fetcher.checkout(source:, destination: checkout, ref: selected_ref).to_s
          unless commit.match?(COMMIT_PATTERN)
            raise Valpo::ValidationError, "Git revision lookup returned an invalid commit SHA"
          end

          result = Result.new(
            checkout:,
            dockerfile: checked_path(checkout, blank_to_default(dockerfile, "Dockerfile"), type: :file),
            context: checked_path(checkout, blank_to_default(context, "."), type: :directory),
            commit: commit.downcase,
            ref: selected_ref
          )
          yield result
        end
      end

      private

      attr_reader :fetcher

      def checked_path(checkout, relative_path, type:)
        root = File.realpath(checkout)
        path = File.realpath(File.join(root, relative_path))
        unless path == root || path.start_with?("#{root}#{File::SEPARATOR}")
          raise Valpo::ValidationError, "Build path must stay within the source checkout: #{relative_path}"
        end

        valid_type = (type == :file) ? File.file?(path) : File.directory?(path)
        raise Valpo::ValidationError, "Build #{type} does not exist: #{relative_path}" unless valid_type

        path
      rescue Errno::ENOENT, Errno::EACCES
        raise Valpo::ValidationError, "Build #{type} does not exist: #{relative_path}"
      end

      def blank_to_default(value, default)
        (value.nil? || value.to_s.empty?) ? default : value.to_s
      end
    end
  end
end
