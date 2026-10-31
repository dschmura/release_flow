# frozen_string_literal: true

require "optparse"

module ReleaseFlow
  # What bin/release runs: parses its options and hands the command to Release.
  module CLI
    module_function

    def start(argv, root:)
      config = Config.load(root)
      options = {}
      args = OptionParser.new do |o|
        o.banner = "#{Release::USAGE}   (see #{config.guide})"
        o.on("--dry-run", "Print the plan without changing anything") { options[:dry_run] = true }
        o.on("--if-needed", "prepare, cut: when there's nothing to do yet, say so and stop without failing") { options[:if_needed] = true }
      end.parse(argv)
      Release.new(options, root: root, config: config).run(*args)
      0
    rescue Error, OptionParser::ParseError => e
      warn("bin/release: #{e.message}")
      1
    end
  end
end
