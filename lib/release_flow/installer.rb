# frozen_string_literal: true

require "erb"
require "fileutils"
require "yaml"

module ReleaseFlow
  # release_flow init: writes the files the flow runs on, keeping any that already exist.
  class Installer
    TEMPLATES = File.expand_path("../../templates", __dir__)
    FILES = {
      "bin/release" => 0o755,
      ".github/workflows/next_release.yml" => 0o644,
      ".github/PULL_REQUEST_TEMPLATE/release.md" => 0o644,
      "changelog.d/README.md" => 0o644
    }.freeze
    CHANGELOG = "# Changelog\n\n#{Changelog::UNRELEASED}"

    def self.start(argv, root:, out: $stdout)
      raise Error, "usage: release_flow init" unless argv == ["init"]

      new(root, out: out).install
      0
    rescue Error => e
      warn("release_flow: #{e.message}")
      1
    end

    def self.render(path, config, ci_name: "CI")
      ERB.new(File.read(File.join(TEMPLATES, "#{path}.erb")), trim_mode: "-").result_with_hash(config: config, ci_name: ci_name)
    end

    def initialize(root, out: $stdout)
      @root = root
      @out = out
      @config = Config.load(root)
    end

    def install
      ci_name = ci_workflow_name
      FILES.each { |path, mode| write(path, mode) { self.class.render(path, @config, ci_name: ci_name) } }
      write("CHANGELOG.md", 0o644) { CHANGELOG }
      unless File.read(File.join(@root, "CHANGELOG.md")).include?(Changelog::UNRELEASED)
        @out.puts("  ! CHANGELOG.md has no #{Changelog::UNRELEASED.strip} heading; add one above your first release")
      end
      @out.puts(<<~NEXT)
        Then: add `bin/release check` to #{@config.ci_workflow}, and to start releases on their own,
        a RELEASE_TOKEN secret and an AUTO_RELEASE variable set to true (#{@config.guide}).
      NEXT
    end

    private

    def ci_workflow_name
      path = File.join(@root, ".github/workflows", @config.ci_workflow)
      unless File.exist?(path)
        raise Error, "no .github/workflows/#{@config.ci_workflow}: set ci_workflow in #{FILE} to the workflow that runs your checks"
      end

      YAML.safe_load_file(path).to_h.fetch("name") { raise Error, "#{@config.ci_workflow} has no name: for the release workflow to wait on" }
    end

    def write(path, mode)
      target = File.join(@root, path)
      return @out.puts("  kept #{path}, which already exists") if File.exist?(target)

      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, yield)
      File.chmod(mode, target)
      @out.puts("  wrote #{path}")
    end
  end
end
