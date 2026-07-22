# frozen_string_literal: true

module RuboCop
  module Cop
    module Valpo
      class ItBlockParameter < Base
        extend AutoCorrector

        MSG = "Use `it` when the block parameter stays within this block scope."
        BLOCK_TYPES = %i[block numblock itblock].freeze

        def on_block(node)
          return unless node.arguments.one?

          argument = node.first_argument
          return unless argument.arg_type?

          references = references_in(node.body, argument.name)
          return if references.empty?

          direct_references = references_in_current_scope(node.body, argument.name)
          return unless references == direct_references

          add_offense(argument, message: MSG) do |corrector|
            corrector.remove(node.arguments)
            direct_references.each { correct_reference(corrector, it) }
          end
        end

        private

        def references_in(node, name)
          return [] unless node

          [node, *node.each_descendant(:lvar)].select { it.lvar_type? && it.children.first == name }
        end

        def references_in_current_scope(node, name)
          return [] unless node
          return [] if BLOCK_TYPES.include?(node.type)

          references = []
          visit = lambda do |current|
            references << current if current.lvar_type? && current.children.first == name
            current.each_child_node do
              visit.call(it) unless BLOCK_TYPES.include?(it.type)
            end
          end
          visit.call(node)
          references
        end

        def correct_reference(corrector, reference)
          pair = reference.parent
          if pair&.pair_type? && pair.value.equal?(reference) && pair.source.end_with?(":")
            corrector.replace(pair, "#{pair.key.source}: it")
          else
            corrector.replace(reference, "it")
          end
        end
      end
    end
  end
end
