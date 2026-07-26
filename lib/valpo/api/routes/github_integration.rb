# frozen_string_literal: true

require "cgi/escape"
require "json"

module Valpo
  module API
    class App
      hash_branch("/integrations", "github") do |r|
        r.get true do
          html(<<~HTML)
            <!doctype html>
            <html lang="en">
              <head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Valpo GitHub integration</title></head>
              <body><main><h1>Valpo GitHub integration</h1><p>This endpoint receives GitHub App callbacks and signed webhooks for this Valpo server.</p></main></body>
            </html>
          HTML
        end

        r.on "setup" do
          r.get true do
            query = validate_query(V1::GitHub::SetupQueryContract)
            form = github_setup.form(query.fetch(:token))
            html(github_manifest_form(
              form.fetch(:manifest),
              state: query.fetch(:token),
              organization: form.fetch(:organization)
            ))
          end
        end

        r.on "callback" do
          r.get true do
            query = validate_query(V1::GitHub::CallbackQueryContract)
            result = github_setup.complete(code: query.fetch(:code), state: query.fetch(:state))
            response.status = 303
            response["Location"] = result.fetch("install_url")
            html(github_redirect_page(result.fetch("install_url")))
          end
        end

        r.on "installation" do
          r.get true do
            query = validate_query(V1::GitHub::InstallationQueryContract)
            installation = github_setup.installation(query.fetch(:installation_id))
            html(github_installation_page(installation))
          end
        end

        r.on "webhook" do
          r.post true do
            validate_query
            body = request.body.read
            unless github_webhook.valid_signature?(body, request.env["HTTP_X_HUB_SIGNATURE_256"])
              response.status = 401
              next({error: "unauthorized", message: "Invalid GitHub webhook signature"})
            end

            result = github_webhook.receive(
              event: request.env["HTTP_X_GITHUB_EVENT"],
              delivery_id: request.env["HTTP_X_GITHUB_DELIVERY"],
              body:
            )
            response.status = 202
            result
          end
        end

        not_found("Route not found")
      end

      private

      def html(value)
        response["Content-Type"] = "text/html; charset=utf-8"
        response["Cache-Control"] = "no-store"
        response["Content-Security-Policy"] = "default-src 'none'; form-action https://github.com; base-uri 'none'; frame-ancestors 'none'"
        response["Referrer-Policy"] = "no-referrer"
        response["X-Content-Type-Options"] = "nosniff"
        value
      end

      def github_manifest_form(manifest, state:, organization:)
        owner_path = organization ? "organizations/#{CGI.escape(organization)}/" : ""
        action = "https://github.com/#{owner_path}settings/apps/new?state=#{CGI.escape(state)}"
        serialized = CGI.escapeHTML(JSON.generate(manifest))
        <<~HTML
          <!doctype html>
          <html lang="en">
            <head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Connect GitHub to Valpo</title></head>
            <body>
              <main>
                <h1>Connect GitHub to Valpo</h1>
                <p>GitHub will ask you to name, create, and install a private GitHub App for this server.</p>
                <form action="#{action}" method="post">
                  <input type="hidden" name="manifest" value="#{serialized}">
                  <button type="submit">Continue to GitHub</button>
                </form>
              </main>
            </body>
          </html>
        HTML
      end

      def github_redirect_page(install_url)
        escaped_url = CGI.escapeHTML(install_url)
        <<~HTML
          <!doctype html>
          <html lang="en">
            <head><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=#{escaped_url}"><title>Install the GitHub App</title></head>
            <body><p>GitHub App created. <a href="#{escaped_url}">Continue to installation</a>.</p></body>
          </html>
        HTML
      end

      def github_installation_page(installation)
        account = CGI.escapeHTML(installation.fetch("account").to_s)
        selection = CGI.escapeHTML(installation.fetch("repository_selection").to_s)
        <<~HTML
          <!doctype html>
          <html lang="en">
            <head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>GitHub connected</title></head>
            <body>
              <main>
                <h1>GitHub connected</h1>
                <p>The GitHub App is installed for #{account} with #{selection} repository access.</p>
                <p>You can close this window and return to Valpo.</p>
              </main>
            </body>
          </html>
        HTML
      end
    end
  end
end
