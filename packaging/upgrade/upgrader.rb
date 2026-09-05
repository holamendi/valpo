# frozen_string_literal: true

# Standalone host tooling: never load Valpo or its application bundle here.
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rubygems/package"
require "securerandom"
require "tempfile"
require "time"
require "timeout"

class ValpoHostUpgrade
  SERVICES = %w[valpo-api.service valpo-worker.service valpo-maintenance.service valpo-migrate.service].freeze
  TIMER = "valpo-maintenance.timer"
  class Error < StandardError; end

  def initialize(root: "/", out: $stdout)
    @root = root
    @prefix = path("opt/valpo")
    @state = path("var/lib/valpo-updater")
    @config = path("etc/valpo/valpo.yml")
    @units = path("etc/systemd/system")
    @pending = File.join(@state, "pending.json")
    @hold = File.join(@state, "hold")
    @metadata_path = File.join(@state, "installation.json")
    @cli = path("usr/local/bin/valpo")
    @out = out
  end

  def synchronize
    FileUtils.mkdir_p(@state, mode: 0o755)
    inherited = ENV["VALPO_UPGRADE_LOCK_FD"]
    lock = inherited ? File.for_fd(Integer(inherited), autoclose: false) : File.open(File.join(@state, "upgrade.lock"), "w", 0o600)
    raise Error, "Another upgrade is running" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
    yield
  ensure
    lock&.close unless inherited
  end

  def apply(archive:, sha256:, channel:)
    raise Error, "Interrupted upgrade; run valpo-upgrade recover first" if File.exist?(@pending)
    raise Error, "Invalid SHA-256 digest" unless /\A[0-9a-f]{64}\z/.match?(sha256)
    raise Error, "Unknown channel" unless %w[development preview stable].include?(channel)
    current = File.symlink?(current_link) ? File.realpath(current_link) : @prefix
    if current != @prefix && File.dirname(current) != File.join(@prefix, "releases")
      raise Error, "Current symlink points outside the supported release layout"
    end
    unless File.file?(@config) && File.file?(File.join(current, "release.json"))
      raise Error, "An existing Valpo installation is required"
    end
    SERVICES.each do
      overrides = Dir[File.join(@units, "#{it}.d", "*")]
      raise Error, "Unsupported systemd overrides for #{it}" if overrides.any? { File.basename(it) != "10-upgrade-guard.conf" }
    end
    release, metadata = stage(archive, sha256, channel)
    previous_metadata = JSON.parse(File.read(File.join(current, "release.json")))
    unless Gem::Version.new(metadata.fetch("version")) > Gem::Version.new(previous_metadata.fetch("version"))
      raise Error, "Upgrades require a higher release version; late rollback is not supported"
    end
    info = probe(release, "inspect")
    database, keyring = info.values_at("database", "keyring")
    raise Error, "Existing database and keyring are required" unless File.file?(database) && File.file?(keyring)
    unless (metadata.fetch("schema_min")..metadata.fetch("schema_target")).cover?(info.fetch("schema"))
      raise Error, "Candidate does not support upgrading the installed schema"
    end
    active = [SERVICES[0], SERVICES[1], TIMER].select { active?(it) }
    raise Error, "API and worker must be active before upgrading" unless (SERVICES.first(2) - active).empty?
    install_guards
    checkpoint = File.join(@state, "checkpoints", Time.now.utc.strftime("%Y%m%dT%H%M%S.%6NZ"))
    FileUtils.mkdir_p(checkpoint, mode: 0o700)
    journal = {"phase" => "quiescing", "active" => active, "checkpoint" => checkpoint,
               "database" => database, "previous" => File.symlink?(current_link) ? File.readlink(current_link) : nil}
    write_json(@pending, journal)
    begin
      atomic_write(@hold, "Upgrade in progress\n", mode: 0o644)
      run("systemctl", "stop", TIMER, SERVICES[2], SERVICES[0])
      if probe(release, "inspect").fetch("busy")
        raise Error, "Jobs are queued or running; retry after they finish"
      end
      run("systemctl", "stop", SERVICES[1], SERVICES[3])
      if probe(release, "inspect").fetch("busy")
        raise Error, "Work appeared while stopping the worker; retry after it finishes"
      end
      files = [database, @config, keyring, @metadata_path, @cli] + SERVICES.map { File.join(@units, it) }
      journal["files"] = files.each_with_index.map { |file, index| snapshot(file, checkpoint, index, contents: index != 0) }
      backup_database(release, checkpoint)
      run("sync", "-f", checkpoint)
      journal["phase"] = "mutating"
      write_json(File.join(checkpoint, "transaction.json"), journal)
      write_json(@pending, journal)
      run(*environment(release), File.join(release, "bin/valpo-migrate"), "--config", @config)
      write_json(@metadata_path, {version: metadata.fetch("version"), channel:,
                                 artifact_digest: "sha256:#{sha256}", installed_at: Time.now.utc.iso8601}, mode: 0o644)
      probe(release, "ready", isolated: true)
      run("sync", "-f", database)
      install_units
      switch(release)
      journal["phase"] = "committed"
      write_json(@pending, journal)
      write_json(File.join(checkpoint, "result.json"), {status: "committed", version: metadata.fetch("version")})
    rescue StandardError, Interrupt # SIGKILL leaves the durable journal for recovery.
      recover
      raise
    end
    resume(journal)
    run("systemctl", "is-active", "--quiet", *SERVICES.first(2))
    @out.puts "Activated #{metadata.fetch("version")}; checkpoint: #{checkpoint}"
  end

  def recover
    raise Error, "No interrupted upgrade to recover" unless File.file?(@pending)
    journal = JSON.parse(File.read(@pending))
    unless %w[committed rolled_back].include?(journal.fetch("phase"))
      if journal.fetch("phase") == "mutating"
        run("systemctl", "stop", TIMER, *SERVICES)
        %w[-wal -shm].each { FileUtils.rm_f(journal.fetch("database") + it) }
        journal.fetch("files").each { restore(it, journal.fetch("checkpoint")) }
        if journal["previous"]
          switch(journal.fetch("previous"))
        else
          FileUtils.rm_f(current_link)
          sync_directory(@prefix)
        end
      end
      journal["phase"] = "rolled_back"
      write_json(@pending, journal)
    end
    resume(journal)
    @out.puts "Recovered upgrade; application containers were left running"
  end

  def stage(source, digest, channel)
    source = File.expand_path(source)
    machine = run("uname", "-m").strip
    architecture = {"x86_64" => "amd64", "aarch64" => "arm64"}[machine]
    match = /\Avalpo-(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)-linux-(amd64|arm64)\.tar\.zst\z/.match(File.basename(source))
    raise Error, "Artifact must identify a release for this host architecture" unless match && match[2] == architecture
    version = match[1]
    raise Error, "Stable channel requires a final release" if channel == "stable" && version.include?("-")
    destination = File.join(@prefix, "releases", version)
    receipt = File.join(@state, "artifacts", "#{version}.json")
    Dir.mktmpdir("stage-", @state) do
      copied = File.join(it, File.basename(source))
      raise Error, "Compressed artifact exceeds 75 MiB" if File.size(source) > 75 * 1024 * 1024
      FileUtils.cp(source, copied)
      raise Error, "Artifact SHA-256 mismatch" unless Digest::SHA256.file(copied).hexdigest == digest
      unless channel == "development"
        run("gh", "attestation", "verify", copied, "--repo", "holamendi/valpo",
          "--signer-workflow", "holamendi/valpo/.github/workflows/release-artifacts.yml",
          "--source-ref", "refs/tags/v#{version}", "--deny-self-hosted-runners")
      end
      if File.exist?(destination)
        unless File.file?(receipt) && JSON.parse(File.read(receipt)).fetch("sha256") == digest
          raise Error, "Immutable release already exists with a different or unknown digest: #{destination}"
        end
        return [destination, JSON.parse(File.read(File.join(destination, "release.json")))]
      end
      tar = File.join(it, "release.tar")
      decompress(copied, tar)
      validate_archive(tar, version)
      payload = File.join(it, "payload")
      FileUtils.mkdir(payload)
      run("tar", "--extract", "--file", tar, "--directory", payload, "--no-same-owner", "--no-same-permissions")
      staged = File.join(payload, "opt/valpo/releases", version)
      Dir.glob(File.join(staged, "**", "*"), File::FNM_DOTMATCH).each do
        next unless File.symlink?(it)
        resolved = File.realpath(it)
        raise Error, "Extracted symlink escapes the release" unless resolved.start_with?(staged + "/")
      end
      metadata = JSON.parse(File.read(File.join(staged, "release.json")))
      unless metadata.fetch("version") == version && metadata.fetch("host_profile") == 1 && metadata.fetch("config_schema") == 1
        raise Error, "Unsupported release metadata or host/config profile"
      end
      FileUtils.mkdir_p(File.dirname(destination), mode: 0o755)
      File.chmod(0o755, File.dirname(destination))
      # tar's no-same-permissions applies the root umask; restore the validated
      # owner-readable/executable payload for the unprivileged service account.
      run("chmod", "-R", "a+rX,go-w", staged)
      File.rename(staged, destination)
      run("chown", "-R", "root:root", destination)
      run("sync", "-f", destination)
      write_json(receipt, {sha256: digest})
      [destination, metadata]
    end
  end

  def validate_archive(file, version)
    root = "opt/valpo/releases/#{version}"
    seen, links, total, long_name, long_link = {}, {}, 0, nil, nil
    pax = {}
    File.open(file, "rb") do |io|
      Gem::Package::TarReader.new(io) do |archive|
        archive.each do
          type = it.header.typeflag
          if type == "x"
            raise Error, "Ambiguous extended tar headers" if !pax.empty? || long_name || long_link
            raise Error, "Oversized PAX header" if it.size > 65_536
            pax = parse_pax(it.read)
            next
          end
          if %w[L K].include?(type)
            raise Error, "Ambiguous extended tar headers" unless pax.empty?
            raise Error, "Oversized GNU tar name" if it.size > 4096
            value = it.read.delete_suffix("\0")
            (type == "L") ? long_name = value : long_link = value
            next
          end
          name = pax.fetch("path", long_name || it.full_name).delete_suffix("/")
          link = pax.fetch("linkpath", long_link || it.header.linkname)
          pax = {}
          long_name = long_link = nil
          safe_name = (name == root || name.start_with?(root + "/")) && !seen[name] && !name.split("/").include?("..") && Pathname.new(name).cleanpath.to_s == name
          unless safe_name
            raise Error, "Unsafe or duplicate archive entry: #{name}"
          end
          raise Error, "Unsupported archive entry: #{name}" unless ["0", "\0", "5", "2"].include?(type)
          raise Error, "Unsafe archive permissions: #{name}" if type != "2" && (it.header.mode & 0o7022).positive?
          if type == "2"
            resolved = Pathname.new(File.join(File.dirname(name), link)).cleanpath.to_s
            raise Error, "Escaping archive symlink: #{name}" if link.start_with?("/") || !resolved.start_with?(root + "/")
            links[name] = true
          end
          seen[name] = true
          total += it.size
          raise Error, "Extracted artifact exceeds 275 MiB" if total > 275 * 1024 * 1024
        end
      end
    end
    seen.each_key do |name|
      Pathname.new(name).parent.ascend { raise Error, "Archive entry traverses a symlink" if links[it.to_s] }
    end
    raise Error, "Incomplete archive" if seen.empty? || long_name || long_link || !pax.empty?
  end

  private

  def path(relative) = File.join(@root, relative)
  def current_link = File.join(@prefix, "current")

  def parse_pax(data)
    fields = {}
    until data.empty?
      prefix = /\A([0-9]+) /.match(data)
      raise Error, "Malformed PAX record" unless prefix
      length = Integer(prefix[1], 10)
      record = data.byteslice(0, length)
      unless length > prefix[0].bytesize && record.bytesize == length && record.end_with?("\n")
        raise Error, "Malformed PAX record length"
      end
      key, value = record.byteslice(prefix[0].bytesize...-1).split("=", 2)
      unless %w[path linkpath mtime].include?(key) && value && !value.include?("\0") && !fields.key?(key)
        raise Error, "Unsupported PAX field: #{key}"
      end
      fields[key] = value
      data = data.byteslice(length..)
    end
    fields
  end

  def run(*args, input: "", chdir: @prefix)
    options = {pgroup: true}
    options[:chdir] = chdir if File.directory?(chdir)
    Open3.popen3(*args, **options) do |stdin, stdout, stderr, wait|
      readers = [stdout, stderr].map { |stream| Thread.new { stream.read } }
      begin
        Timeout.timeout(120) do
          stdin.write(input)
          stdin.close
          status = wait.value
          output, error = readers.map(&:value)
          raise Error, "#{args.first} failed (#{status.exitstatus}): #{error.lines.last(8).join.strip}" unless status.success?
          output
        end
      ensure
        # A timed-out/aborted probe may leave an API child; kill the whole group
        # before any checkpoint restore, even when the direct child has exited.
        begin
          Process.kill("KILL", -wait.pid)
        rescue Errno::ESRCH
          nil
        end
        stdin.close unless stdin.closed?
        readers.each(&:join)
        wait.join
      end
    end
  end

  def active?(unit)
    run("systemctl", "is-active", "--quiet", unit)
    true
  rescue Error
    false
  end

  def decompress(source, destination)
    Open3.popen3("zstd", "-dc", source, pgroup: true) do |stdin, stdout, stderr, wait|
      stdin.close
      errors = Thread.new { stderr.read }
      begin
        Timeout.timeout(120) do
          File.open(destination, "wb") do
            total = 0
            while (chunk = stdout.read(1024 * 1024))
              total += chunk.bytesize
              raise Error, "Decompressed archive exceeds 350 MiB" if total > 350 * 1024 * 1024
              it.write(chunk)
            end
          end
          raise Error, "Artifact decompression failed: #{errors.value}" unless wait.value.success?
        end
      ensure
        begin
          Process.kill("KILL", -wait.pid)
        rescue Errno::ESRCH
          nil
        end
        errors.join
        wait.join
      end
    end
  end

  def environment(release)
    ["/usr/sbin/runuser", "-u", "valpo", "--", "/usr/bin/env", "-i",
      "HOME=/var/lib/valpo", "USER=valpo", "LANG=C.UTF-8", "VALPO_ENV=production", "VALPO_CONFIG=#{@config}",
      "BUNDLE_GEMFILE=#{release}/Gemfile", "RUBYLIB=#{release}/bundle",
      "PATH=#{release}/tools:#{release}/runtime/ruby/bin:/usr/local/bin:/usr/bin:/bin"]
  end

  def probe(release, mode, *arguments, isolated: false)
    command = environment(release)
    command << "VALPO_API_HOST=127.0.0.1" if isolated
    command += ["#{release}/runtime/ruby/bin/ruby", "-I#{release}/lib", "-", mode, *arguments]
    if isolated
      command = ["unshare", "--net", "--", "sh", "-ec", 'ip link set lo up; exec "$@"', "probe"] + command
    end
    JSON.parse(run(*command, input: File.read(File.join(__dir__, "probe.rb")), chdir: release))
  end

  def backup_database(release, checkpoint)
    # Only this empty scratch directory is writable by the service account.
    # Final checkpoint files and the recovery journal remain root-only.
    scratch = File.join(@state, "backup-#{SecureRandom.hex(8)}")
    FileUtils.mkdir(scratch, mode: 0o700)
    run("chown", "valpo:valpo", scratch)
    begin
      probe(release, "backup", File.join(scratch, "database"))
      atomic_write(File.join(checkpoint, "0"), File.binread(File.join(scratch, "database")))
    ensure
      FileUtils.rm_rf(scratch)
    end
  end

  def sync_directory(directory)
    File.open(directory, File::RDONLY, &:fsync)
  end

  def atomic_write(file, data, mode: 0o600, owner: nil)
    FileUtils.mkdir_p(File.dirname(file))
    Tempfile.create(".upgrade-", File.dirname(file)) do
      it.binmode
      it.write(data)
      it.chmod(mode)
      it.chown(*owner) if owner
      it.flush
      it.fsync
      File.rename(it.path, file)
    end
    sync_directory(File.dirname(file))
  end

  def write_json(file, data, mode: 0o600)
    atomic_write(file, JSON.pretty_generate(data) + "\n", mode:)
  end

  def switch(target)
    temporary = File.join(@prefix, ".current-next")
    FileUtils.rm_f(temporary)
    File.symlink(target, temporary)
    File.rename(temporary, current_link)
    sync_directory(@prefix)
  end

  def snapshot(file, checkpoint, index, contents: true)
    raise Error, "Expected regular host file: #{file}" if File.symlink?(file) || (File.exist?(file) && !File.file?(file))
    saved = {"path" => file, "exists" => File.exist?(file)}
    if saved.fetch("exists")
      stat = File.stat(file)
      saved.merge!("mode" => stat.mode & 0o777, "uid" => stat.uid, "gid" => stat.gid, "copy" => index.to_s)
      atomic_write(File.join(checkpoint, index.to_s), contents ? File.binread(file) : "")
    end
    saved
  end

  def restore(saved, checkpoint)
    if saved.fetch("exists")
      atomic_write(saved.fetch("path"), File.binread(File.join(checkpoint, saved.fetch("copy"))),
        mode: saved.fetch("mode"), owner: saved.values_at("uid", "gid"))
    else
      FileUtils.rm_f(saved.fetch("path"))
      sync_directory(File.dirname(saved.fetch("path"))) if File.directory?(File.dirname(saved.fetch("path")))
    end
  end

  def install_guards
    SERVICES.each do
      atomic_write(File.join(@units, "#{it}.d", "10-upgrade-guard.conf"),
        "[Service]\nExecCondition=/usr/bin/test ! -e #{@hold}\n", mode: 0o644)
    end
    run("systemctl", "daemon-reload")
  end

  def install_units
    SERVICES.each do
      command = it.delete_suffix(".service")
      long_running = SERVICES.first(2).include?(it)
      atomic_write(File.join(@units, it), <<~UNIT, mode: 0o644)
        [Unit]
        Description=Valpo #{command}
        After=network-online.target docker.service
        Wants=network-online.target

        [Service]
        Type=#{long_running ? "simple" : "oneshot"}
        User=valpo
        Group=valpo
        UMask=0077
        WorkingDirectory=/opt/valpo/current
        Environment=VALPO_ENV=production
        Environment=VALPO_CONFIG=/etc/valpo/valpo.yml
        Environment=HOME=/var/lib/valpo
        ExecStart=/opt/valpo/current/bin/#{command} --config /etc/valpo/valpo.yml
        #{"Restart=on-failure\nRestartSec=5" if long_running}

        [Install]
        WantedBy=multi-user.target
      UNIT
    end
    atomic_write(@cli, <<~SH, mode: 0o755)
      #!/bin/sh
      set -eu
      if [ "$(id -u)" = 0 ]; then
        exec runuser -u valpo -- "$0" "$@"
      fi
      export VALPO_ENV=production VALPO_CONFIG=/etc/valpo/valpo.yml HOME=/var/lib/valpo
      cd /opt/valpo/current
      exec /opt/valpo/current/bin/valpo "$@"
    SH
    run("systemctl", "daemon-reload")
  end

  def resume(journal)
    FileUtils.rm_f(@hold)
    sync_directory(@state)
    run("systemctl", "daemon-reload")
    journal.fetch("active").each { run("systemctl", "start", it) }
    File.unlink(@pending)
    sync_directory(@state)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = {}
    parser = OptionParser.new
    parser.banner = "Usage: valpo-upgrade apply ARCHIVE --sha256 DIGEST --channel CHANNEL | recover"
    parser.on("--sha256 DIGEST") { options[:sha256] = it }
    parser.on("--channel CHANNEL") { options[:channel] = it }
    parser.parse!(ARGV)
    command, archive = ARGV
    valid_command = (command == "recover" && ARGV.size == 1) || (command == "apply" && ARGV.size == 2 && options.size == 2)
    raise ValpoHostUpgrade::Error, parser.to_s unless valid_command
    raise ValpoHostUpgrade::Error, "Run the host updater as root" unless Process.euid.zero?
    os = File.read("/etc/os-release")
    raise ValpoHostUpgrade::Error, "Only Ubuntu 26.04 is supported" unless os.match?(/^ID=ubuntu$/) && os.match?(/^VERSION_ID="26\.04"$/)
    File.umask(0o077)
    Signal.trap("TERM") { raise Interrupt, "Upgrade interrupted" }
    updater = ValpoHostUpgrade.new
    updater.synchronize { (command == "recover") ? updater.recover : updater.apply(archive:, **options) }
  rescue StandardError, Interrupt => e
    warn "valpo-upgrade: #{e.message}"
    exit 1
  end
end
