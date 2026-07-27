# frozen_string_literal: true

module Valpo
  module GitHub
    class Authentication
      def initialize(credentials: nil, personal_access_token: nil, client: nil)
        @credentials = credentials || Credentials.new
        @personal_access_token = personal_access_token || PersonalAccessToken.new
        @client = client || Client.new(credentials: @credentials)
      end

      def token_for(repository)
        return client.installation_token(repository) if credentials.configured?

        personal_access_token.read
      end

      private

      attr_reader :credentials, :personal_access_token, :client
    end
  end
end
