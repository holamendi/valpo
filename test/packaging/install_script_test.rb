# frozen_string_literal: true

require "open3"
require "test_helper"

class ValpoPackagingInstallScriptTest < Minitest::Test
  INSTALL_SCRIPT = File.expand_path("../../packaging/install.sh", __dir__)
  API_SERVICE = File.expand_path("../../packaging/systemd/valpo-api.service", __dir__)
  WORKER_SERVICE = File.expand_path("../../packaging/systemd/valpo-worker.service", __dir__)
  MIGRATE_SERVICE = File.expand_path("../../packaging/systemd/valpo-migrate.service", __dir__)
  EXAMPLE_CONFIG = File.expand_path("../../packaging/valpo.yml.example", __dir__)

  def test_installer_has_valid_bash_syntax
    stdout, stderr, status = Open3.capture3("bash", "-n", INSTALL_SCRIPT)

    assert status.success?, [stdout, stderr].join("\n")
  end

  def test_installer_help_does_not_require_root
    stdout, stderr, status = Open3.capture3("bash", INSTALL_SCRIPT, "--help")

    assert status.success?, stderr
    assert_includes stdout, "Usage: sudo packaging/install.sh"
    assert_includes stdout, "--state-dir PATH"
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

  def test_installer_uses_locked_bundler_without_rewriting_source
    script = File.read(INSTALL_SCRIPT)

    assert_includes script, "locked_bundler_version()"
    assert_includes script, "Gemfile.lock must include BUNDLED WITH"
    assert_includes script, "gem install bundler -v '${bundler_version}'"
    assert_includes script, "bundle _${bundler_version}_ config set --global frozen true"
    assert_includes script, "bundle _${bundler_version}_ install --jobs 4 --retry 3"
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
    [API_SERVICE, WORKER_SERVICE, MIGRATE_SERVICE].each do |path|
      service = File.read(path)

      assert_includes service, "Environment=HOME=/var/lib/valpo"
      assert_includes service, "Environment=MISE_RUBY_COMPILE=false"
      assert_includes service, "/var/lib/valpo/.local/bin/mise x ruby@4.0.5 -- bundle exec"
    end
  end
end
