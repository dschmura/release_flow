# frozen_string_literal: true

module ReleaseFlow
  class Error < StandardError; end
end

require_relative "release_flow/version"
require_relative "release_flow/git_env"
require_relative "release_flow/config"
require_relative "release_flow/github_origin"
require_relative "release_flow/changelog"
require_relative "release_flow/candidate"
require_relative "release_flow/release"
require_relative "release_flow/installer"
require_relative "release_flow/cli"
