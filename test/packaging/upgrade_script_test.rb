# frozen_string_literal: true

require "fileutils"
require "json"
require "sqlite3"
require "stringio"
require "test_helper"
require "tmpdir"
require_relative "../../packaging/upgrade/upgrader"

class ValpoPackagingUpgradeScriptTest < Minitest::Test
  class Host < ValpoHostUpgrade
    attr_accessor :failure, :busy
    attr_reader :commands, :database, :keyring, :release

    def initialize(root:)
      super(root:, out: StringIO.new)
      @commands = []
      @database = File.join(root, "valpo.db")
      @keyring = File.join(root, "master.key")
      @release = File.join(root, "opt/valpo/releases/0.1.1")
      FileUtils.mkdir_p(@release)
      FileUtils.mkdir_p(File.dirname(@config))
      FileUtils.mkdir_p(@state)
      File.write(@config, "original config")
      File.write(@keyring, "original key", mode: "w", perm: 0o600)
      File.write(File.join(@prefix, "release.json"), JSON.generate(version: "0.1.0"))
      SQLite3::Database.new(@database) do
        it.execute_batch("CREATE TABLE schema_info(version); INSERT INTO schema_info VALUES(6); CREATE TABLE items(value); INSERT INTO items VALUES('original');")
      end
    end

    def stage(*) = [@release, {"version" => "0.1.1", "schema_min" => 1, "schema_target" => 7}]

    private

    def active?(*) = true

    def run(*args, **)
      @commands << args
      if args.any? { it.end_with?("bin/valpo-migrate") }
        raise "missing admission guard" unless File.exist?(@hold)
        SQLite3::Database.new(@database) do
          it.execute("UPDATE schema_info SET version=7")
          it.execute("UPDATE items SET value='migrated'")
        end
        raise Error, "migration failed" if failure == :migration
      end
      raise Error, "restart failed" if failure == :restart && args.first(2) == %w[systemctl start]
      ""
    end

    def probe(_release, mode, isolated: false)
      return {"database" => @database, "keyring" => @keyring, "schema" => 6, "busy" => !!busy} if mode == "inspect"
      raise "readiness must be isolated and guarded" unless isolated && File.exist?(@hold)
      if failure == :readiness
        File.write(@config, "candidate config")
        File.write(@keyring, "candidate key")
        raise Error, "readiness failed"
      end
      {"ok" => true}
    end

    def backup_database(_release, checkpoint)
      SQLite3::Database.new(@database) do |source|
        SQLite3::Database.new(File.join(checkpoint, "0")) do
          backup = SQLite3::Backup.new(it, "main", source, "main")
          backup.step(-1)
          backup.finish
        end
      end
    end
  end

  def setup
    @temporary = Dir.mktmpdir("valpo-upgrade")
    @host = Host.new(root: @temporary)
    @state = File.join(@temporary, "var/lib/valpo-updater")
    @pending = File.join(@state, "pending.json")
    @hold = File.join(@state, "hold")
    @current = File.join(@temporary, "opt/valpo/current")
  end

  def teardown
    FileUtils.remove_entry(@temporary)
  end

  def apply
    @host.apply(archive: "valpo-0.1.1-linux-amd64.tar.zst", sha256: "a" * 64, channel: "development")
  end

  def value(path = @host.database)
    result = nil
    SQLite3::Database.new(path) { result = it.get_first_value("SELECT value FROM items") }
    result
  end

  def test_success_activates_release_and_retains_checkpoint_without_touching_containers
    apply
    assert_equal @host.release, File.readlink(@current)
    assert_equal "migrated", value
    refute_path_exists @hold
    refute_path_exists @pending
    assert_equal "original", value(Dir[File.join(@state, "checkpoints/*/0")].fetch(0))
    metadata = JSON.parse(File.read(File.join(@state, "installation.json")))
    assert_equal "sha256:#{"a" * 64}", metadata.fetch("artifact_digest")
    refute @host.commands.any? { it.include?("docker") }
    assert_includes File.read(File.join(@temporary, "etc/systemd/system/valpo-api.service")), "/opt/valpo/current/bin/valpo-api"
  end

  def test_migration_failure_restores_database_and_source_installation
    @host.failure = :migration
    assert_match(/migration failed/, assert_raises(ValpoHostUpgrade::Error) { apply }.message)
    assert_equal "original", value
    refute_path_exists @current
    refute_path_exists @hold
    refute_path_exists @pending
  end

  def test_readiness_failure_restores_configuration_keyring_and_metadata_together
    @host.failure = :readiness
    assert_raises(ValpoHostUpgrade::Error) { apply }
    assert_equal "original", value
    assert_equal "original config", File.read(File.join(@temporary, "etc/valpo/valpo.yml"))
    assert_equal "original key", File.read(@host.keyring)
    assert_equal 0o600, File.stat(@host.keyring).mode & 0o777
    refute_path_exists File.join(@state, "installation.json")
  end

  def test_busy_host_is_rejected_without_stopping_worker
    @host.busy = true
    assert_match(/queued or running/, assert_raises(ValpoHostUpgrade::Error) { apply }.message)
    refute @host.commands.any? { it.first(2) == %w[systemctl stop] && it.include?("valpo-worker.service") }
    assert_equal "original", value
    refute_path_exists @pending
  end

  def test_committed_restart_failure_recovers_without_discarding_new_writes
    @host.failure = :restart
    assert_raises(ValpoHostUpgrade::Error) { apply }
    assert_equal "committed", JSON.parse(File.read(@pending)).fetch("phase")
    SQLite3::Database.new(@host.database) { it.execute("UPDATE items SET value='new user write'") }
    @host.failure = nil
    @host.recover
    assert_equal "new user write", value
    assert_equal @host.release, File.readlink(@current)
    refute_path_exists @pending
  end

  def test_interrupted_mutation_can_be_recovered_by_a_new_updater_instance
    @host.failure = :migration
    @host.stub(:recover, nil) { assert_raises(ValpoHostUpgrade::Error) { apply } }
    assert_equal "migrated", value
    assert_path_exists @hold
    replacement = ValpoHostUpgrade.new(root: @temporary, out: StringIO.new)
    replacement.stub(:run, "") { replacement.recover }
    assert_equal "original", value
    refute_path_exists @hold
  end

  def test_recovery_restores_previous_packaged_symlink
    previous = File.join(@temporary, "opt/valpo/releases/0.1.0")
    FileUtils.mkdir_p(previous)
    File.write(File.join(previous, "release.json"), JSON.generate(version: "0.1.0"))
    File.symlink(previous, @current)
    @host.failure = :readiness
    assert_raises(ValpoHostUpgrade::Error) { apply }
    assert_equal previous, File.readlink(@current)
  end

  def test_pending_upgrade_blocks_a_second_transaction
    File.write(@pending, "{}")
    assert_match(/Interrupted upgrade/, assert_raises(ValpoHostUpgrade::Error) { apply }.message)
    assert_empty @host.commands
  end

  def test_bootstrap_lock_is_inherited_without_unlocking_it
    previous = ENV["VALPO_UPGRADE_LOCK_FD"]
    File.open(File.join(@state, "upgrade.lock"), "w") do |lock|
      lock.flock(File::LOCK_EX)
      ENV["VALPO_UPGRADE_LOCK_FD"] = lock.fileno.to_s
      reached = false
      @host.synchronize { reached = true }
      assert reached
      refute lock.closed?
      File.open(lock.path, "w") { refute it.flock(File::LOCK_EX | File::LOCK_NB) }
    end
  ensure
    ENV["VALPO_UPGRADE_LOCK_FD"] = previous
  end

  def test_recovery_journal_survives_failure_while_restoring
    @host.failure = :migration
    @host.stub(:recover, nil) { assert_raises(ValpoHostUpgrade::Error) { apply } }
    @host.stub(:restore, ->(*) { raise IOError, "disk unavailable" }) do
      assert_raises(IOError) { @host.recover }
    end
    assert_path_exists @hold
    assert_equal "mutating", JSON.parse(File.read(@pending)).fetch("phase")
  end

  def test_archive_rejects_traversal_duplicates_devices_and_symlink_children
    root = "opt/valpo/releases/0.1.1"
    [
      [["#{root}/../escape", :file]],
      [["etc/shadow", :file]],
      [["#{root}/file", :file], ["#{root}/file", :file]],
      [["#{root}/link", :link, "/etc"]],
      [["#{root}/link", :link, "target"], ["#{root}/link/file", :file]]
    ].each do
      tar = archive(it)
      assert_raises(ValpoHostUpgrade::Error) { @host.validate_archive(tar, "0.1.1") }
    end
  end

  def test_archive_accepts_normal_payload_and_internal_links
    root = "opt/valpo/releases/0.1.1"
    tar = archive([["#{root}/file", :file], ["#{root}/alias", :link, "file"]])
    @host.validate_archive(tar, "0.1.1")
  end

  def test_pax_paths_are_supported_and_validated_before_extraction
    root = "opt/valpo/releases/0.1.1"
    @host.validate_archive(pax_archive("#{root}/#{"long" * 35}/file"), "0.1.1")
    assert_raises(ValpoHostUpgrade::Error) { @host.validate_archive(pax_archive("#{root}/../escape"), "0.1.1") }
  end

  def test_checksum_mismatch_is_rejected_before_extraction
    artifact = File.join(@temporary, "valpo-0.1.1-linux-amd64.tar.zst")
    File.write(artifact, "unverified contents")
    updater = ValpoHostUpgrade.new(root: @temporary)
    updater.stub(:run, "x86_64\n") do
      assert_match(/SHA-256 mismatch/, assert_raises(ValpoHostUpgrade::Error) { updater.stage(artifact, "b" * 64, "development") }.message)
    end
  end

  private

  def pax_archive(name)
    payload = "path=#{name}\n"
    length = payload.bytesize + 3
    length = payload.bytesize + length.to_s.bytesize + 1 until length == payload.bytesize + length.to_s.bytesize + 1
    record = "#{length} #{payload}"
    target = File.join(@temporary, "pax.tar")
    File.open(target, "wb") do |io|
      io.write(Gem::Package::TarHeader.new(name: "Pax", prefix: "", mode: 0o644, size: record.bytesize, typeflag: "x").to_s)
      io.write(record)
      io.write("\0" * ((512 - record.bytesize % 512) % 512))
      Gem::Package::TarWriter.new(io) { it.add_file_simple("opt/valpo/releases/0.1.1/file", 0o644, 0) {} }
    end
    target
  end

  def archive(entries)
    target = File.join(@temporary, "payload.tar")
    File.open(target, "wb") do |io|
      Gem::Package::TarWriter.new(io) do |tar|
        entries.each do |name, type, link|
          if type == :link
            tar.add_symlink(name, link, 0o777)
          else
            tar.add_file_simple(name, 0o644, 0) {}
          end
        end
      end
    end
    target
  end
end
