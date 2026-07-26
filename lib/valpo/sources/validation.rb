# frozen_string_literal: true

module Valpo
  module Sources
    module Validation
      module_function

      def github_ref(value)
        value = value.to_s
        return value if value.match?(Valpo::Sources::GitHub::REF_PATTERN)

        raise Valpo::ValidationError, "GitHub ref must be a branch, tag, or commit SHA without whitespace"
      end

      def relative_path(value, key:)
        path = Pathname.new(value)
        clean = path.cleanpath.to_s
        if path.absolute? || clean == ".." || clean.start_with?("../")
          raise Valpo::ValidationError, "#{key} must stay within the source checkout"
        end

        clean
      end
    end
  end
end
