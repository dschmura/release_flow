# frozen_string_literal: true

require "open3"

module ReleaseFlow
  # The GitHub repository a checkout's origin names. gh prefers a remote called upstream,
  # so the flow asks for origin by name instead.
  module GithubOrigin
    URL = %r{github\.com[:/](?<repo>[^/\s]+/[^/\s]+?)(?:\.git)?/?\z}

    module_function

    def repo(root)
      url, status = Open3.capture2(GitEnv::HASH, "git", "-C", root, "config", "--get", "remote.origin.url", err: File::NULL)
      url.strip[URL, :repo] if status.success?
    end
  end
end
