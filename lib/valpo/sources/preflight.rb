# frozen_string_literal: true

require "tmpdir"

module Valpo
  module Sources
    class Preflight
      COMMIT_PATTERN = /\A[0-9a-f]{40,64}\z/i
      Candidate = Data.define(:provider, :repository, :ref)
      SourceResult = Data.define(:checkout, :commit, :ref)
      Result = Data.define(:checkout, :strategy, :dockerfile, :context, :commit, :ref)

      def initialize(fetcher:)
        @fetcher = fetcher
      end

      def with_checkout(provider:, repository:, ref: "HEAD", strategy: "auto", dockerfile: nil, context: ".")
        with_source_checkout(provider:, repository:, ref:) do
          yield validate_checkout(
            source: it,
            strategy:,
            dockerfile:,
            context:
          )
        end
      end

      def with_source_checkout(provider:, repository:, ref: "HEAD")
        selected_ref = blank_to_default(ref, "HEAD")
        source = Candidate.new(provider:, repository:, ref: selected_ref)

        Dir.mktmpdir("valpo-source-") do
          checkout = it
          commit = fetcher.checkout(source:, destination: checkout, ref: selected_ref).to_s
          unless commit.match?(COMMIT_PATTERN)
            raise Valpo::ValidationError, "Git revision lookup returned an invalid commit SHA"
          end

          yield SourceResult.new(checkout:, commit: commit.downcase, ref: selected_ref)
        end
      end

      def validate_checkout(source:, strategy: "auto", dockerfile: nil, context: ".")
        context_value = blank_to_default(context, ".")
        checked_context = checked_path(source.checkout, context_value, type: :directory)
        resolved_strategy, checked_dockerfile = resolve_strategy(
          checkout: source.checkout,
          strategy:,
          dockerfile:,
          context: context_value
        )
        Result.new(
          checkout: source.checkout,
          strategy: resolved_strategy,
          dockerfile: checked_dockerfile,
          context: checked_context,
          commit: source.commit,
          ref: source.ref
        )
      end

      private

      attr_reader :fetcher

      def resolve_strategy(checkout:, strategy:, dockerfile:, context:)
        case strategy
        when "dockerfile"
          ["dockerfile", checked_path(checkout, blank_to_default(dockerfile, "Dockerfile"), type: :file)]
        when "buildpack"
          ["buildpack", nil]
        when "auto"
          candidate = File.join(context, "Dockerfile")
          unresolved = File.join(checkout, candidate)
          return ["buildpack", nil] unless File.exist?(unresolved) || File.symlink?(unresolved)

          ["dockerfile", checked_path(checkout, candidate, type: :file)]
        else
          raise Valpo::ValidationError, "Unsupported build strategy: #{strategy}"
        end
      end

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
