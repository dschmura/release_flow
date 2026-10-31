# frozen_string_literal: true

require "release_flow"
require "tmpdir"
require "stringio"

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.order = :random
end
