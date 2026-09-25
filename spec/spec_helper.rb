# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'socket'
require 'stringio'
require 'tmpdir'

load File.expand_path('../figma-sync', __dir__)
require_relative 'support/figma_sync_helpers'

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.mock_with(:rspec) { |m| m.verify_partial_doubles = true }
  config.disable_monkey_patching!
  config.define_derived_metadata { |meta| meta[:aggregate_failures] = true }
  config.order = :random
  Kernel.srand(config.seed)
  config.include FigmaSyncHelpers
  config.after { FigmaSync::Client.close_sessions }
end
