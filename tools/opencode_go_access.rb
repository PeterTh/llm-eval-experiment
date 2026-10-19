#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative "../lib/opencode_go"

if $PROGRAM_NAME == __FILE__
  model, auth_file = ARGV
  abort "usage: opencode_go_access.rb MODEL AUTH_FILE" unless model && auth_file && ARGV.size == 2
  puts JSON.generate(OpenCodeGo.check(auth_file: auth_file, model: model))
end
