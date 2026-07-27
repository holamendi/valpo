# frozen_string_literal: true

require "open3"
require "fileutils"
require "test_helper"
require "tmpdir"

class ValpoPackagingInstallScriptTest < Minitest::Test
  BOOTSTRAP_SCRIPT = File.expand_path("../../packaging/bootstrap.sh", __dir__)
  INSTALL_SCRIPT = File.expand_path("../../packaging/install.sh", __dir__)
  UNINSTALL_SCRIPT = File.expand_path("../../packaging/uninstall.sh", __dir__)
  CLEAN_INSTALL_SMOKE_SCRIPT = File.expand_path("../../packaging/vps-clean-install-smoke-test.sh", __dir__)
  VPS_SMOKE_SCRIPT = File.expand_path("../../packaging/vps-smoke-test.sh", __dir__)
  SOURCE_SMOKE_SCRIPT = File.expand_path("../../packaging/vps-source-smoke-test.sh", __dir__)
  API_SERVICE = File.expand_path("../../packaging/systemd/valpo-api.service", __dir__)
  WORKER_SERVICE = File.expand_path("../../packaging/systemd/valpo-worker.service", __dir__)
  MIGRATE_SERVICE = File.expand_path("../../packaging/systemd/valpo-migrate.service", __dir__)
  EXAMPLE_CONFIG = File.expand_path("../../packaging/valpo.yml.example", __dir__)
  PRE_COMMIT_HOOK = File.expand_path("../../.githooks/pre-commit", __dir__)
  CI_WORKFLOW = File.expand_path("../../.github/workflows/ci.yml", __dir__)
  SHELL_SCRIPTS = [
    PRE_COMMIT_HOOK,
    *Dir[File.expand_path("../../packaging/**/*.sh", __dir__)]
  ].sort.freeze

  def test_all_tracked_shell_scripts_have_valid_bash_syntax
    SHELL_SCRIPTS.each do
      stdout, stderr, status = Open3.capture3("bash", "-n", it)

      assert status.success?, "#{it}\n#{[stdout, stderr].join("\n")}"
    end
  end

  def test_bootstrap_help_does_not_require_root
    stdout, stderr, status = Open3.capture3("bash", BOOTSTRAP_SCRIPT, "--help")

    assert status.success?, stderr
    assert_includes stdout, "curl -fsSL"
    assert_includes stdout, "mutable development snapshot"
    assert_includes stdout, "not a versioned or reproducible production release installer"
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

  def test_installer_and_services_keep_database_state_private
    script = File.read(INSTALL_SCRIPT)

    assert_includes script, "umask 077"
    assert_includes script, 'chmod 0600 "${STATE_DIR}/valpo.db"'
    assert_includes script, 'chown root:"$VALPO_GROUP" "$CONFIG_PATH"'
    assert_includes script, 'chmod 0640 "$CONFIG_PATH"'
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

  def test_clean_install_smoke_test_requires_destructive_confirmation
    script = File.read(CLEAN_INSTALL_SMOKE_SCRIPT)
    stdout, stderr, status = Open3.capture3("bash", CLEAN_INSTALL_SMOKE_SCRIPT, "--help")

    assert status.success?, stderr
    assert_includes stdout, "--confirm-destroy-valpo"
    assert_includes script, "bash '$remote_uninstaller'"
    assert_includes script, "smoke_options+=(--full-install)"
  end

  def test_primary_vps_smoke_test_help_is_available_without_a_remote_host
    stdout, stderr, status = Open3.capture3("bash", VPS_SMOKE_SCRIPT, "--help")

    assert status.success?, stderr
    assert_includes stdout, "Usage: packaging/vps-smoke-test.sh"
    assert_includes stdout, "--full-install"
  end

  def test_installer_has_no_public_layout_or_lifecycle_flags
    script = File.read(INSTALL_SCRIPT)

    %w[--source --prefix --config --state-dir --app-domain --skip-deps --no-start].each do
      refute_includes script, it
    end
    assert_includes script, "VALPO_INSTALL_SKIP_DEPS"
    assert_includes script, "VALPO_INSTALL_NO_START"
  end

  def test_installer_uses_one_fixed_host_identity_and_ruby
    script = File.read(INSTALL_SCRIPT)

    assert_includes script, 'RUBY_VERSION="4.0.5"'
    assert_includes script, 'VALPO_USER="valpo"'
    assert_includes script, 'VALPO_GROUP="valpo"'
    refute_includes script, "VALPO_RUBY_VERSION"
    refute_match(/VALPO_USER=.*:-/, script)
    refute_match(/VALPO_GROUP=.*:-/, script)
  end

  def test_installer_requires_ubuntu_26_04
    script = File.read(INSTALL_SCRIPT)

    assert_includes script, '"${ID:-}" == "ubuntu"'
    assert_includes script, '"${VERSION_ID:-}" == "26.04"'
    assert_includes script, "This installer supports Ubuntu 26.04 LTS only"
  end

  def test_installer_rejects_bootstrap_schema_changes_before_mutation
    script = File.read(INSTALL_SCRIPT)
    main = script.match(/main\(\) \{\n(?<body>.*?)\n\}/m).named_captures.fetch("body")

    assert_includes script, "preflight_bootstrap_schema()"
    assert_includes script, 'incoming_schema="${SOURCE_DIR}/db/migrations/001_bootstrap.rb"'
    assert_includes script, 'installed_schema="${PREFIX}/db/migrations/001_bootstrap.rb"'
    assert_includes script, '[[ "$incoming_sha" == "$installed_sha" ]]'
    assert_operator main.index("preflight_bootstrap_schema"), :<, main.index("install_packages")
  end

  def test_bootstrap_schema_preflight_accepts_a_match_and_rejects_a_change
    Dir.mktmpdir("valpo-schema-preflight") do
      incoming = File.join(it, "incoming")
      installed = File.join(it, "installed")
      state = File.join(it, "state")
      config_path = File.join(it, "valpo.yml")
      [incoming, installed].each do
        FileUtils.mkdir_p(File.join(it, "db", "migrations"))
        File.write(File.join(it, "db", "migrations", "001_bootstrap.rb"), "same schema\n")
      end
      FileUtils.mkdir_p(state)
      FileUtils.touch(File.join(state, "valpo.db"))
      FileUtils.touch(config_path)

      command = <<~BASH
        install_script="$1"
        incoming="$2"
        installed="$3"
        state="$4"
        config_path="$5"
        set --
        source "$install_script"
        SOURCE_DIR="$incoming"
        PREFIX="$installed"
        STATE_DIR="$state"
        CONFIG_PATH="$config_path"
        preflight_bootstrap_schema
      BASH
      _stdout, stderr, status = Open3.capture3(
        "bash", "-c", command, "preflight", INSTALL_SCRIPT, incoming, installed, state, config_path
      )
      assert status.success?, stderr

      File.write(File.join(incoming, "db", "migrations", "001_bootstrap.rb"), "changed schema\n")
      _stdout, stderr, status = Open3.capture3(
        "bash", "-c", command, "preflight", INSTALL_SCRIPT, incoming, installed, state, config_path
      )
      refute status.success?
      assert_includes stderr, "Bootstrap schema changed"

      File.write(File.join(incoming, "db", "migrations", "001_bootstrap.rb"), "same schema\n")
      FileUtils.rm_f(config_path)
      _stdout, stderr, status = Open3.capture3(
        "bash", "-c", command, "preflight", INSTALL_SCRIPT, incoming, installed, state, config_path
      )
      refute status.success?
      assert_includes stderr, "installed Valpo layout is incomplete"
    end
  end

  def test_installer_preserves_existing_config_and_copies_the_example_for_a_new_install
    script = File.read(INSTALL_SCRIPT)

    assert_includes script, 'if [[ -e "$CONFIG_PATH" ]]'
    assert_includes script, 'log "Preserving existing ${CONFIG_PATH}"'
    assert_includes script, 'install -o root -g "$VALPO_GROUP" -m 0640 "${PREFIX}/packaging/valpo.yml.example" "$CONFIG_PATH"'
    refute_includes script, 'cat > "$tmp" <<CONFIG'
    refute_includes script, '"${CONFIG_PATH}.bak.'
  end

  def test_config_writer_preserves_existing_bytes_and_uses_the_example_for_a_new_file
    Dir.mktmpdir("valpo-config-writer") do
      prefix = File.join(it, "prefix")
      config_path = File.join(it, "valpo.yml")
      FileUtils.mkdir_p(File.join(prefix, "packaging"))
      File.write(File.join(prefix, "packaging", "valpo.yml.example"), "template bytes\n")
      File.write(config_path, "operator bytes\n")

      command = <<~BASH
        install_script="$1"
        prefix="$2"
        config_path="$3"
        set --
        source "$install_script"
        PREFIX="$prefix"
        CONFIG_PATH="$config_path"
        install() { cp "${@: -2:1}" "${@: -1}"; }
        chown() { :; }
        write_valpo_config
      BASH
      _stdout, stderr, status = Open3.capture3(
        "bash", "-c", command, "config-writer", INSTALL_SCRIPT, prefix, config_path
      )
      assert status.success?, stderr
      assert_equal "operator bytes\n", File.read(config_path)
      assert_equal 0o640, File.stat(config_path).mode & 0o777

      FileUtils.rm_f(config_path)
      _stdout, stderr, status = Open3.capture3(
        "bash", "-c", command, "config-writer", INSTALL_SCRIPT, prefix, config_path
      )
      assert status.success?, stderr
      assert_equal "template bytes\n", File.read(config_path)
      assert_equal 0o640, File.stat(config_path).mode & 0o777
    end
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
    assert_includes script, 'awk -v start="$start_marker"'
    assert_includes File.read(UNINSTALL_SCRIPT), "pending_blanks"
    assert_includes config, "caddy_config_path: /var/lib/valpo/caddy/valpo.caddy"
    assert_includes config, "caddy_reload_config_path: /etc/caddy/Caddyfile"
  end

  def test_installer_and_uninstaller_use_ownership_labels
    installer = File.read(INSTALL_SCRIPT)
    uninstaller = File.read(UNINSTALL_SCRIPT)
    clean_smoke = File.read(CLEAN_INSTALL_SMOKE_SCRIPT)

    assert_includes installer, "docker network create --label valpo.owned=true valpo"
    %w[ps volume network].each do
      assert_includes uninstaller, "docker #{it}"
    end
    assert_equal 3, uninstaller.scan("--filter label=valpo.owned=true").length
    assert_equal 3, clean_smoke.scan("--filter label=valpo.owned=true").length
    refute_includes uninstaller, "grep '^valpo-'"
    refute_includes uninstaller, "docker image rm"
    refute_includes uninstaller, "reference=valpo/*"
  end

  def test_systemd_units_run_through_mise
    [API_SERVICE, WORKER_SERVICE, MIGRATE_SERVICE].each do
      service = File.read(it)

      assert_includes service, "Environment=HOME=/var/lib/valpo"
      assert_includes service, "Environment=MISE_RUBY_COMPILE=false"
      assert_includes service, "/var/lib/valpo/.local/bin/mise x ruby@4.0.5 -- bundle exec"
    end
  end

  def test_installer_creates_private_encryption_key_storage
    script = File.read(INSTALL_SCRIPT)
    config = File.read(EXAMPLE_CONFIG)

    assert_includes script, 'install -d -o "$VALPO_USER" -g "$VALPO_GROUP" -m 0700 "${STATE_DIR}/secrets"'
    assert_includes config, "encryption_key_path: /var/lib/valpo/secrets/master.key"
  end

  def test_source_smoke_test_preserves_the_github_credential
    script = File.read(SOURCE_SMOKE_SCRIPT)

    assert_includes script, "valpo auth status github --json"
    assert_includes script, "provider_credentials"
    refute_includes script, "auth logout"
    assert_includes script, "--source 'github:${repository}' --deploy"
  end

  def test_primary_smoke_test_never_reveals_managed_secrets
    script = File.read(File.expand_path("../../packaging/vps-smoke-test.sh", __dir__))

    assert_includes script, "environment_output=\"$(remote \"valpo service env list '${web_service}' --project '${project}'\")\""
    assert_includes script, "valpo service env set"
    assert_includes script, "Custom environment plaintext leaked into SQLite"
    assert_includes script, "valpo service env unset"
    assert_includes script, "DATABASE_URL PGPASSWORD REDIS_URL REDIS_PASSWORD"
    assert_includes script, "grep -F '********'"
    assert_includes script, "postgres(ql)?://|redis://"
    assert_includes script, "revealed_output=\\$(valpo service env list '${web_service}' --project '${project}' --reveal)"
    assert_includes script, "grep -F -- \\\"\\$secret_value\\\""
  end

  def test_pre_commit_hook_is_check_only
    hook = File.read(PRE_COMMIT_HOOK)

    assert_includes hook, "bundle exec rake test standard cli:docs:check api:check docs:check"
    refute_match(/--fix|--autocorrect/, hook)
  end

  def test_ci_runs_the_supported_host_checks_with_immutable_actions
    workflow = File.read(CI_WORKFLOW)

    assert_includes workflow, "branches: [main]"
    assert_includes workflow, "runs-on: ubuntu-26.04"
    assert_includes workflow, "uses: ruby/setup-ruby@"
    assert_includes workflow, 'ruby-version: "4.0.5"'
    assert_includes workflow, "bundler-cache: true"
    assert_includes workflow, "bundle exec rake test"
    assert_includes workflow, "bundle exec rake standard"
    assert_includes workflow, "bundle exec rake cli:docs:check api:check docs:check"
    assert_includes workflow, "bash -n"
    assert_includes workflow, "shellcheck"
    workflow.scan(/uses: ([^@\s]+)@([^\s]+)/).each do |name, revision|
      assert_match(/\A[0-9a-f]{40}\z/, revision, "#{name} must use an immutable commit SHA")
    end
  end
end
