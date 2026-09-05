# frozen_string_literal: true

module Valpo
  module LifecycleTransitions
    def self.included(model)
      model.extend(ClassMethods)
    end

    module ClassMethods
      def transition_dataset!(dataset, from:, to:, **attributes)
        from = Array(from).map(&:to_s)
        to = to.to_s
        invalid = from.reject { lifecycle_transitions.fetch(it, []).include?(to) }
        unless invalid.empty?
          raise Valpo::ValidationError, "Forbidden #{table_name} transition from #{invalid.join(", ")} to #{to}"
        end

        dataset.where(status: from).update(attributes.merge(status: to))
      end

      def lifecycle_transitions
        self::TRANSITIONS
      end
    end

    def transition_to!(target, **attributes)
      target = target.to_s
      return update(attributes) if target == status && !attributes.empty?
      return self if target == status

      allowed = self.class.lifecycle_transitions.fetch(status, [])
      unless allowed.include?(target)
        raise Valpo::ValidationError, "Forbidden #{model_name} transition from #{status} to #{target}"
      end

      update(attributes.merge(status: target))
    end

    private

    def model_name
      self.class.name.split("::").last.gsub(/([a-z])([A-Z])/, "\\1 \\2").downcase
    end
  end
end
