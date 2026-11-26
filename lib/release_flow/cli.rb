# frozen_string_literal: true

require "optparse"

module ReleaseFlow
  # What bin/release runs: parses its options and hands the command to Release.
  module CLI
    module_function

    def start(argv, root:, config: nil)
      config ||= Config.load(root)
      options = {}
      parser = OptionParser.new do |o|
        o.banner = "#{Release::USAGE}   (see #{config.guide})"
        o.on("--dry-run", "Print the plan without changing anything") { options[:dry_run] = true }
        o.on("--if-needed", "prepare, cut: when there's nothing to do yet, say so and stop without failing") { options[:if_needed] = true }
        o.on("--wait", "prepare, cut, ship, merge-back: follow the PR it opened until the next step is yours") { options[:wait] = true }
        o.on("--timeout MINUTES", Integer, "with --wait: give up after this long (default 45)") { |m| options[:timeout] = m * 60 }
        o.on("-h", "--help", "Show this") { options[:help] = true }
      end
      args = parser.parse(argv)
      return puts(parser.help) || 0 if options[:help]

      Release.new(options, root: root, config: config).run(*args)
      0
    rescue Release::Stopped => e
      warn("bin/release: #{e.message}")
      130
    rescue Error, OptionParser::ParseError => e
      warn("bin/release: #{e.message}")
      1
    end
  end
end
