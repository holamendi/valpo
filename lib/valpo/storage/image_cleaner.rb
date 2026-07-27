# frozen_string_literal: true

require "json"
require "time"

module Valpo
  module Storage
    class ImageCleaner
      def initialize(docker:, retention_count:, grace_period:, clock: -> { Time.now.utc })
        @docker = docker
        @retention_count = retention_count
        @grace_period = grace_period
        @clock = clock
      end

      def call(dry_run:, queue:, job_id:)
        releases = Valpo::Release.where(source_type: "git", artifact_available: true).all
        protected = protected_releases(releases)
        protected_references = protected.filter_map { image_reference(it) }.to_set
        protected_artifacts = protected.flat_map { artifact_identifiers(it) }.to_set
        candidates = releases.reject { protected.include?(it) }
          .group_by { image_reference(it) }
          .reject { |reference, _group| reference.nil? || protected_references.include?(reference) }

        images = local_images
        removed_releases = 0
        removed_references = 0
        candidates.sort.each do |reference, group|
          next unless removable_reference?(reference, group, images, protected_artifacts)

          if dry_run
            event(queue, job_id, "Would remove stale image #{reference}")
            removed_references += 1
            removed_releases += group.length
            next
          end

          result = docker.execute(docker.image_rm_command(reference))
          unless result.fetch(:success) || missing_image?(result)
            warning(queue, job_id, "Could not remove stale image #{reference}: #{command_detail(result)}")
            next
          end

          remove_local_ids(group, protected_artifacts, queue:, job_id:)
          group.each { it.update(artifact_available: false) }
          removed_references += 1
          removed_releases += group.length
          event(queue, job_id, "Removed stale image #{reference}")
        end

        {image_references: removed_references, release_artifacts: removed_releases}
      end

      def remove_for_service(service_id:, queue:, job_id:)
        releases = Valpo::Release.where(
          service_id:,
          source_type: "git",
          artifact_available: true
        ).all
        return {image_references: 0, release_artifacts: 0} if releases.empty?

        protected = Valpo::Release.where(source_type: "git", artifact_available: true)
          .exclude(service_id:)
          .all
        protected_references = protected.filter_map { image_reference(it) }.to_set
        protected_artifacts = protected.flat_map { artifact_identifiers(it) }.to_set
        removed_references = 0
        removed_releases = 0

        releases.group_by { image_reference(it) }.sort.each do |reference, group|
          next if reference.nil? || protected_references.include?(reference)
          next if group.flat_map { artifact_identifiers(it) }.any? { protected_artifacts.include?(it) }

          result = docker.execute(docker.image_rm_command(reference))
          unless result.fetch(:success) || missing_image?(result)
            warning(queue, job_id, "Could not remove service image #{reference}: #{command_detail(result)}")
            next
          end

          remove_local_ids(group, protected_artifacts, queue:, job_id:)
          group.each { it.update(artifact_available: false) }
          removed_references += 1
          removed_releases += group.length
          event(queue, job_id, "Removed service image #{reference}")
        end
        {image_references: removed_references, release_artifacts: removed_releases}
      end

      private

      attr_reader :docker, :retention_count, :grace_period, :clock

      def protected_releases(releases)
        cutoff = clock.call - grace_period
        protected = releases.select do
          %w[pending ready active].include?(it.status) || it.created_at >= cutoff
        end.to_set
        releases.group_by(&:service_id).each_value do |service_releases|
          service_releases
            .select { %w[ready active inactive].include?(it.status) }
            .sort_by(&:version)
            .last(retention_count)
            .each { protected << it }
        end
        protected
      end

      def image_reference(release)
        return release.artifact_ref if release.artifact_ref.to_s.start_with?("valpo/")

        target = release.build_target
        service = release.service
        return unless target && service

        "valpo/#{service.project.name}/#{target.name}:#{release.source_ref.to_s[0, 12]}"
      end

      def artifact_identifiers(release)
        [release.artifact_ref, release.image_digest].compact.reject(&:empty?)
      end

      def local_images
        result = docker.execute(docker.image_list_command)
        raise Valpo::ValidationError, "Could not list Docker images: #{command_detail(result)}" unless result.fetch(:success)

        result.fetch(:stdout).lines.filter_map do
          next if it.strip.empty?

          JSON.parse(it)
        end
      rescue JSON::ParserError => e
        raise Valpo::ValidationError, "Docker image list returned invalid JSON: #{e.message}"
      end

      def listed_reference(image)
        repository = image["Repository"].to_s
        tag = image["Tag"].to_s
        return if repository.empty? || repository == "<none>" || tag.empty? || tag == "<none>"

        "#{repository}:#{tag}"
      end

      def removable_reference?(reference, releases, images, protected_artifacts)
        return false if releases.any? { it.created_at >= clock.call - grace_period }

        image = images.find { listed_reference(it) == reference }
        return true unless image
        return false if protected_artifacts.include?(image["ID"])

        releases.any? || older_than_grace?(image["CreatedAt"])
      end

      def older_than_grace?(value)
        Time.parse(value.to_s) < clock.call - grace_period
      rescue ArgumentError
        false
      end

      def remove_local_ids(releases, protected_artifacts, queue:, job_id:)
        releases.flat_map { artifact_identifiers(it) }
          .select { it.match?(/\Asha256:[0-9a-f]+\z/) }
          .uniq
          .reject { protected_artifacts.include?(it) }
          .each do
            result = docker.execute(docker.image_rm_command(it))
            next if result.fetch(:success) || missing_image?(result) || referenced_image?(result)

            warning(queue, job_id, "Could not remove untagged image #{it}: #{command_detail(result)}")
          end
      end

      def missing_image?(result)
        result.fetch(:stderr).to_s.match?(/No such image|No such object/i)
      end

      def referenced_image?(result)
        result.fetch(:stderr).to_s.match?(/is being used|image is referenced/i)
      end

      def command_detail(result)
        result.fetch(:stderr).to_s.strip.then { it.empty? ? result.fetch(:stdout).to_s.strip : it }
      end

      def event(queue, job_id, message)
        queue.event(job_id, "system", message)
      end

      def warning(queue, job_id, message)
        queue.event(job_id, "stderr", message)
      end
    end
  end
end
