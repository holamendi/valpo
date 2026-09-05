# frozen_string_literal: true

statuses = {
  services: %w[created provisioning ready running stopped restarting deleting failed],
  releases: %w[pending ready active inactive failed],
  service_dependencies: %w[binding active deleting failed],
  domains: %w[pending verified failed],
  platform_domains: %w[pending verified failed],
  jobs: %w[queued running succeeded failed]
}.freeze

Sequel.migration do
  up do
    invalid = statuses.filter_map do |table, allowed|
      rows = from(table).exclude(status: allowed).select_map([:id, :status])
      next if rows.empty?

      "#{table}: #{rows.map { |id, status| "#{id}=#{status.inspect}" }.join(", ")}"
    end
    unless invalid.empty?
      raise Sequel::Error,
        "Lifecycle invariant preflight failed. Repair the listed rows to a documented state and rerun migration 003: #{invalid.join("; ")}"
    end

    duplicate_release_services = from(:releases)
      .where(status: "active")
      .group(:service_id)
      .having { count.function.* > 1 }
      .select_map(:service_id)
    duplicate_release_services.each do
      releases = from(:releases).where(service_id: it, status: "active").order(Sequel.desc(:version), Sequel.desc(:created_at), Sequel.desc(:id))
      keep = releases.get(:id)
      releases.exclude(id: keep).update(status: "inactive")
      warn "migration 003 repaired duplicate active releases for service #{it}; kept #{keep}"
    end

    active_platform_domains = from(:platform_domains).where(active: true)
      .order(Sequel.desc(:verified_at), Sequel.desc(:created_at), Sequel.desc(:id))
      .select_map(:id)
    unless active_platform_domains.empty?
      verified_ids = from(:platform_domains).where(id: active_platform_domains, status: "verified").select_map(:id)
      keep = active_platform_domains.find { verified_ids.include?(it) }
      from(:platform_domains).where(id: active_platform_domains).exclude(id: keep).update(active: false)
      warn "migration 003 repaired active platform domains; kept #{keep || "none (no verified domain)"}" if active_platform_domains.length > 1 || keep.nil?
    end

    statuses.each do |table, allowed|
      alter_table(table) do
        add_constraint(:"#{table}_status_valid", status: allowed)
      end
    end
    alter_table(:platform_domains) do
      add_constraint(:platform_domains_active_verified) { (active =~ false) | (status =~ "verified") }
    end
    alter_table(:releases) do
      add_index :service_id,
        unique: true,
        where: Sequel.lit("status = 'active'"),
        name: :releases_one_active_per_service
    end
    alter_table(:platform_domains) do
      add_index :active,
        unique: true,
        where: Sequel.lit("active = 1"),
        name: :platform_domains_one_active
    end
  end

  down do
    alter_table(:platform_domains) { drop_index :active, name: :platform_domains_one_active }
    alter_table(:releases) { drop_index :service_id, name: :releases_one_active_per_service }
    alter_table(:platform_domains) { drop_constraint :platform_domains_active_verified }
    statuses.each_key do |table|
      alter_table(table) { drop_constraint :"#{table}_status_valid" }
    end
  end
end
