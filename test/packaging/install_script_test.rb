# frozen_string_literal: true

require "open3"
require "test_helper"

class ValpoPackagingInstallScriptTest < Minitest::Test
  BOOTSTRAP_SCRIPT = File.expand_path("../../packaging/bootstrap.sh", __dir__)
  INSTALL_SCRIPT = File.expand_path("../../packaging/install.sh", __dir__)
  UNINSTALL_SCRIPT = File.expand_path("../../packaging/uninstall.sh", __dir__)
  CLEAN_INSTALL_SMOKE_SCRIPT = File.expand_path("../../packaging/vps-clean-install-smoke-test.sh", __dir__)
  SOURCE_SMOKE_SCRIPT = File.expand_path("../../packaging/vps-source-smoke-test.sh", __dir__)
  API_SERVICE = File.expand_path("../../packaging/systemd/valpo-api.service", __dir__)
  WORKER_SERVICE = File.expand_path("../../packaging/systemd/valpo-worker.service", __dir__)
  MIGRATE_SERVICE = File.expand_path("../../packaging/systemd/valpo-migrate.service", __dir__)
  EXAMPLE_CONFIG = File.expand_path("../../packaging/valpo.yml.example", __dir__)

  def test_installer_has_valid_bash_syntax
    stdout, stderr, status = Open3.capture3("bash", "-n", INSTALL_SCRIPT)

    assert status.success?, [stdout, stderr].join("\n")
  end

  def test_bootstrap_has_valid_bash_syntax
    stdout, stderr, status = Open3.capture3("bash", "-n", BOOTSTRAP_SCRIPT)

    assert status.success?, [stdout, stderr].join("\n")
  end

  def test_bootstrap_help_does_not_require_root
    stdout, stderr, status = Open3.capture3("bash", BOOTSTRAP_SCRIPT, "--help")

    assert status.success?, stderr
    assert_includes stdout, "curl -fsSL"
    refute_includes stdout, "--ref"
    refute_includes stdout, "--sha256"
  end

  def test_bootstrap_downloads_a_private_archive_and_runs_the_source_installer
    script = File.read(BOOTSTRAP_SCRIPT)

    assert_includes script, "umask 077"
    assert_includes script, "https://github.com/${REPOSITORY}/archive/${REF}.tar.gz"
    assert_includes script, "--proto '=https' --proto-redir '=https' --tlsv1.2"
    assert_includes script, "--strip-components=1"
    assert_includes script, "trap cleanup EXIT"
    assert_includes script, 'bash "${SOURCE_DIR}/packaging/install.sh"'
  end

  def test_source_smoke_test_has_valid_bash_syntax
    stdout, stderr, status = Open3.capture3("bash", "-n", SOURCE_SMOKE_SCRIPT)

    assert status.success?, [stdout, stderr].join("\n")
  end

  def test_installer_and_services_keep_database_state_private
    script = File.read(INSTALL_SCRIPT)

    assert_includes script, "umask 077"
    assert_includes script, 'chmod 0600 "${STATE_DIR}/valpo.db"'
    [API_SERVICE, WORKER_SERVICE, MIGRATE_SERVICE].each do
      assert_includes File.read(it), "UMask=0077"
    end
  end

  def test_installer_help_does_not_require_root
    stdout, stderr, status = Open3.capture3("bash", INSTALL_SCRIPT, "--help")

    assert status.success?, stderr
    assert_includes stdout, "Usage: packaging/install.sh"
    refute_includes stdout, "--state-dir"
    refute_includes stdout, "--app-domain"
  end

  def test_uninstaller_and_clean_install_smoke_test_have_valid_bash_syntax
    [UNINSTALL_SCRIPT, CLEAN_INSTALL_SMOKE_SCRIPT].each do
      stdout, stderr, status = Open3.capture3("bash", "-n", it)

      assert status.success?, [stdout, stderr].join("\n")
    end
  end

  def test_clean_install_smoke_test_requires_destructive_confirmation
    script = File.read(CLEAN_INSTALL_SMOKE_SCRIPT)
    stdout, stderr, status = Open3.capture3("bash", CLEAN_INSTALL_SMOKE_SCRIPT, "--help")

    assert status.success?, stderr
    assert_includes stdout, "--confirm-destroy-valpo"
    assert_includes script, "bash '$remote_uninstaller'"
    assert_includes script, "smoke_options+=(--full-install)"
  end

  def test_installer_has_no_public_layout_or_lifecycle_flags
    script = File.read(INSTALL_SCRIPT)

    %w[--source --prefix --config --state-dir --app-domain --skip-deps --no-start].each do
      refute_includes script, it
    end
    assert_includes script, "VALPO_INSTALL_SKIP_DEPS"
    assert_includes script, "VALPO_INSTALL_NO_START"
  end

  def test_installer_enforces_precompiled_mise_ruby
    script = File.read(INSTALL_SCRIPT)

    assert_includes script, "MISE_RUBY_COMPILE=false"
    assert_includes script, "settings set ruby.compile false"
    assert_includes script, "precompiled Ruby is required"
    assert_match(/ruby-build\|building ruby\|compiling ruby/, script)
  end

  def test_installer_puts_mise_on_path_for_valpo_shell_commands
    script = File.read(INSTALL_SCRIPT)

    assert_includes script, "PATH=\"${STATE_DIR}/.local/bin:${PATH}\""
  end

  def test_installer_pins_pack_with_architecture_checksums
    script = File.read(INSTALL_SCRIPT)
    config = File.read(EXAMPLE_CONFIG)

    assert_includes script, 'PACK_VERSION="0.40.8"'
    assert_includes script, 'PACK_PATH="${STATE_DIR}/.local/bin/pack"'
    assert_includes script, 'PACK_AMD64_SHA256="3b8cfd4287ea6c648ccff9c17cbfa61ae615839071a5de804f3b84316ed99a93"'
    assert_includes script, 'PACK_ARM64_SHA256="51b1b8ba93f3cff0e25fdc4c099daddd962ea2c691ccd13bd607f0a452c42039"'
    assert_includes script, "sha256sum --check --status"
    assert_includes script, "install_pack"
    assert_includes File.read(WORKER_SERVICE), "Environment=PATH=/var/lib/valpo/.local/bin:"
    assert_includes config, "build_timeout: 1800"
    assert_includes config, Valpo::Config::DEFAULT_BUILDPACK_BUILDER
  end

  def test_installer_uses_locked_bundler_without_rewriting_source
    script = File.read(INSTALL_SCRIPT)

    assert_includes script, "locked_bundler_version()"
    assert_includes script, "Gemfile.lock must include BUNDLED WITH"
    assert_includes script, "gem install bundler -v '${bundler_version}'"
    assert_includes script, "bundle _${bundler_version}_ config set --global frozen true"
    assert_includes script, "bundle _${bundler_version}_ install --jobs 4 --retry 3"
  end

  def test_installer_installs_valpo_cli_wrapper_on_path
    script = File.read(INSTALL_SCRIPT)

    assert_includes script, 'CLI_PATH="/usr/local/bin/valpo"'
    assert_includes script, "install_cli_wrapper()"
    assert_includes script, 'install -m 0755 "$tmp" "$CLI_PATH"'
    assert_includes script, 'exec runuser -u "\${VALPO_USER}" -- "\$0" "\$@"'
    assert_includes script, 'exec "\${MISE_BIN}" x ruby@"\${RUBY_VERSION}" -- bundle exec exe/valpo "\$@"'
  end

  def test_installer_uses_valpo_owned_caddy_import
    script = File.read(INSTALL_SCRIPT)
    config = File.read(EXAMPLE_CONFIG)

    assert_includes script, "CADDY_GENERATED_PATH=\"${STATE_DIR}/caddy/valpo.caddy\""
    assert_includes script, "import ${CADDY_GENERATED_PATH}"
    assert_includes config, "caddy_config_path: /var/lib/valpo/caddy/valpo.caddy"
    assert_includes config, "caddy_reload_config_path: /etc/caddy/Caddyfile"
  end

  def test_systemd_units_run_through_mise
    [API_SERVICE, WORKER_SERVICE, MIGRATE_SERVICE].each do
      service = File.read(it)

      assert_includes service, "Environment=HOME=/var/lib/valpo"
      assert_includes service, "Environment=MISE_RUBY_COMPILE=false"
      assert_includes service, "/var/lib/valpo/.local/bin/mise x ruby@4.0.5 -- bundle exec"
    end
  end

  def test_installer_creates_private_github_credential_storage
    script = File.read(INSTALL_SCRIPT)
    config = File.read(EXAMPLE_CONFIG)

    assert_includes script, 'install -d -o "$VALPO_USER" -g "$VALPO_GROUP" -m 0700 "${STATE_DIR}/secrets"'
    assert_includes config, "github_token_path: /var/lib/valpo/secrets/github-token"
  end

  def test_source_smoke_test_preserves_the_github_credential
    script = File.read(SOURCE_SMOKE_SCRIPT)

    assert_includes script, "valpo auth status github --json"
    assert_includes script, "sha256sum /var/lib/valpo/secrets/github-token"
    refute_includes script, "auth logout"
    refute_match(/rm\s+[^\n]*github-token/, script)
    assert_includes script, "--source 'github:${repository}' --deploy"
  end
end
