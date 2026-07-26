# frozen_string_literal: true

module Valpo
  module Sources
    class GitHub
      FINE_GRAINED_PAT_URL = "https://github.com/settings/personal-access-tokens/new?name=Valpo&description=Source+deployments+for+Valpo&expires_in=90&contents=read"
      REPOSITORY_PATTERN = /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]+\z/
      REF_PATTERN = /\A[^\x00-\x20\x7f]+\z/

      def initialize(token: nil, git: "git", runner: GitCommandRunner.new, askpass_path: File.join(Valpo.root, "exe", "valpo-git-askpass"))
        @token = token
        @git = git
        @runner = runner
        @askpass_path = askpass_path
      end

      def checkout(source:, destination:, ref: nil)
        repository = source.repository.to_s
        selected_ref = (ref || source.ref).to_s
        validate_repository!(repository)
        validate_ref!(selected_ref)

        run(command("-C", destination, "init", "--quiet"), "Git checkout setup failed")
        run(
          command("-C", destination, "remote", "add", "origin", "https://github.com/#{repository}.git"),
          "Git remote setup failed"
        )
        run(
          command("-C", destination, "fetch", "--quiet", "--depth=1", "--no-tags", "--", "origin", selected_ref),
          "GitHub fetch failed",
          authenticated: true,
          repository:
        )
        run(command("-C", destination, "checkout", "--quiet", "--detach", "FETCH_HEAD"), "Git checkout failed")
        run(command("-C", destination, "rev-parse", "HEAD"), "Git revision lookup failed").fetch(:stdout).strip
      end

      private

      attr_reader :git, :runner, :askpass_path

      def token(repository)
        return @token unless @token.respond_to?(:call)

        (@token.arity == 0) ? @token.call : @token.call(repository)
      end

      def command(*arguments)
        [git, "-c", "credential.helper=", *arguments]
      end

      def environment(authenticated:, repository: nil)
        values = {"GIT_TERMINAL_PROMPT" => "0"}
        if authenticated && (resolved_token = token(repository))
          values["GIT_ASKPASS"] = askpass_path
          values["GIT_ASKPASS_REQUIRE"] = "force"
          values["VALPO_GIT_ASKPASS_TOKEN"] = resolved_token
        end
        values
      end

      def run(command, message, authenticated: false, repository: nil)
        result = runner.capture(environment(authenticated:, repository:), command)
        return result if result.fetch(:success)

        detail = result.fetch(:stderr).to_s.strip
        detail = result.fetch(:stdout).to_s.strip if detail.empty?
        detail = "exit #{result.fetch(:status)}" if detail.empty?
        raise Valpo::ValidationError, "#{message}: #{detail}"
      end

      def validate_repository!(repository)
        return if repository.match?(REPOSITORY_PATTERN)

        raise Valpo::ValidationError, "GitHub repository must be an owner/repository name"
      end

      def validate_ref!(ref)
        return if ref.match?(REF_PATTERN)

        raise Valpo::ValidationError, "GitHub ref must be a branch, tag, or commit SHA without whitespace"
      end
    end
  end
end
