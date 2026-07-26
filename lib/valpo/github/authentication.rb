# frozen_string_literal: true

module Valpo
  module GitHub
    class Authentication
      def initialize(config:, credentials: nil, client: nil)
        @config = config
        @credentials = credentials || Credentials.new(config.github_app_credentials_path)
        @client = client || Client.new(credentials: @credentials)
      end

      def token_for(repository)
        return client.installation_token(repository) if credentials.configured?

        config.github_token
      end

      private

      attr_reader :config, :credentials, :client
    end
  end
end
