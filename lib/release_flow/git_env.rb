# frozen_string_literal: true

# Cleared before every git spawn: a hook's GIT_DIR beats `git -C`.
module ReleaseFlow
  module GitEnv
    HASH = {
      "GIT_DIR" => nil,
      "GIT_WORK_TREE" => nil,
      "GIT_INDEX_FILE" => nil,
      "GIT_COMMON_DIR" => nil,
      "GIT_OBJECT_DIRECTORY" => nil,
      "GIT_NAMESPACE" => nil,
      "GIT_CONFIG" => nil,
      "GIT_CONFIG_GLOBAL" => nil,
      "GIT_CONFIG_SYSTEM" => nil,
      "GIT_CONFIG_COUNT" => nil
    }.freeze
  end
end
