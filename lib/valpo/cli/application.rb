# frozen_string_literal: true

module Valpo
  module CLI
    class Application < Dry::CLI
      private

      def parse(command, arguments, names)
        built_command, parsed = super
        extras = Array(parsed[:args]).dup
        built_command.optional_arguments.each do
          argument = it
          Array(parsed[argument.name]).each do
            extras.shift if extras.first == it
          end
        end
        extras.empty? ? parsed.delete(:args) : parsed[:args] = extras
        [built_command, parsed]
      end

      def help(command, program_name)
        canonical_name = program_name.sub(/\A\S+/, "valpo")
        out.puts Dry::CLI::Banner.call(command, canonical_name)
        raise HelpShown
      end

      def error(result)
        raise UsageError, result.error
      end

      def spell_checker(result, arguments)
        suggestion = Dry::CLI::SpellChecker.call(result, arguments)
        message = []
        message << suggestion if suggestion
        message << Dry::CLI::Usage.call(result)
        raise UsageError, message.join("\n\n")
      end
    end
  end
end
