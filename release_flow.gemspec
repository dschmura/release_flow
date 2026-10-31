# frozen_string_literal: true

require_relative "lib/release_flow/version"

Gem::Specification.new do |spec|
  spec.name = "release_flow"
  spec.version = ReleaseFlow::VERSION
  spec.authors = ["Dave Chmura"]
  spec.email = ["dschmura@humbledaisy.com"]

  spec.summary = "Release a GitHub repository through staging review: each release is the commit someone checked"
  spec.description = "A next → release/<name> → main release flow on git and the GitHub CLI. Changelog entries live in " \
                     "changelog.d/ so they never conflict; a release is named, cut to staging, reviewed, and shipped " \
                     "as exactly the commit staging ran, tagged with its notes."
  spec.homepage = "https://github.com/dschmura/release_flow"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE.txt", "CHANGELOG.md"] +
    Dir.glob("templates/**/*", File::FNM_DOTMATCH).select { |f| File.file?(f) }
  spec.bindir = "exe"
  spec.executables = ["release_flow"]
  spec.require_paths = ["lib"]
end
