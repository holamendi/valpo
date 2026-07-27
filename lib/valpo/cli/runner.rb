# frozen_string_literal: true

module Valpo
  module CLI
    class Runner
      GLOBAL_VALUE_OPTIONS = %w[--api-url].freeze
      GLOBAL_BOOLEAN_OPTIONS = %w[--json --no-json].freeze

      def initialize(out:, err:)
        @out = out
        @err = err
      end

      def call(arguments)
        arguments = normalize_help(Array(arguments).dup)
        arguments = normalize_global_options(arguments)
        return render_group_help(help_path(arguments)) if group_help?(arguments)

        Application.new(Registry).call(arguments:, out:, err:)
        0
      rescue HelpShown
        0
      rescue UsageError => e
        err.puts usage_message(e.message, arguments)
        2
      rescue OperationalError, Valpo::API::Client::Error, Valpo::ValidationError, Valpo::ConflictError => e
        err.puts e.message
        1
      rescue KeyError => e
        err.puts "Invalid API response: #{e.message}"
        1
      end

      private

      attr_reader :out, :err

      def normalize_help(arguments)
        return ["--help"] if arguments.empty?
        return ["--help"] if arguments == ["help"]
        return arguments.drop(1) + ["--help"] if arguments.first == "help"

        arguments
      end

      def normalize_global_options(arguments)
        global = []
        command = []
        index = 0
        while index < arguments.length
          argument = arguments[index]
          if GLOBAL_BOOLEAN_OPTIONS.include?(argument) || GLOBAL_VALUE_OPTIONS.any? { argument.start_with?("#{it}=") }
            global << argument
          elsif GLOBAL_VALUE_OPTIONS.include?(argument)
            global << argument
            index += 1
            global << arguments[index] if arguments[index]
          else
            command << argument
          end
          index += 1
        end
        command + global
      end

      def group_help?(arguments)
        return false unless arguments.last == "--help"

        path = help_path(arguments)
        lookup = Registry.get(path)
        !lookup.found? && !lookup.children.empty?
      end

      def help_path(arguments)
        path = []
        index = 0
        while index < arguments.length
          argument = arguments[index]
          if argument == "--help" || GLOBAL_BOOLEAN_OPTIONS.include?(argument) || GLOBAL_VALUE_OPTIONS.any? { argument.start_with?("#{it}=") }
            # Omit help and global flags from the command path.
          elsif GLOBAL_VALUE_OPTIONS.include?(argument)
            index += 1
          else
            path << argument
          end
          index += 1
        end
        path
      end

      def render_group_help(path)
        prefix = path.join(" ")
        out.puts path.empty? ? "Valpo command-line interface" : Registry::GROUPS.fetch(prefix)
        out.puts
        out.puts "Usage:"
        out.puts "  valpo #{"#{prefix} " unless prefix.empty?}COMMAND [options]"
        out.puts
        out.puts "Commands:"
        commands_for(path).each do |name, command|
          out.puts "  #{name.ljust(18)} #{command.description}"
        end
        if path.empty?
          out.puts
          out.puts "Run `valpo help COMMAND` for command-specific help."
        end
        0
      end

      def commands_for(path)
        if path.empty?
          groups = Registry::GROUPS.except("job").map { |name, description| [name, GroupDescription.new(description)] }
          groups + [["version", Commands::Version]]
        else
          prefix = "#{path.join(" ")} "
          Registry::COMMANDS.filter_map do |name, command, _hidden|
            next unless name.start_with?(prefix) && name.split.length == path.length + 1

            [name.delete_prefix(prefix), command]
          end
        end
      end

      def canonicalize(message)
        message.to_s.sub(/\A\s*/, "").gsub(File.basename($PROGRAM_NAME), "valpo")
      end

      def usage_message(message, arguments)
        canonical = canonicalize(message)
        path = arguments.take_while { !it.start_with?("-") }.take(2)
        suggestion = path.empty? ? "Run `valpo --help` for usage." : "Run `valpo #{path.join(" ")} --help` for usage."
        "#{canonical}\n#{suggestion}"
      end

      GroupDescription = Struct.new(:description)
    end
  end
end
