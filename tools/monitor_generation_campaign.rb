#!/usr/bin/env ruby
# frozen_string_literal: true
require "json"
campaign = File.read(File.join(__dir__, "campaign.path")).strip
manifest = JSON.parse(File.read(File.join(campaign, "campaign.json")))
require File.join(manifest.fetch("working_directory"), "tools/generation_campaign")
GenerationCampaign.new(campaign).status
status = JSON.parse(File.read(File.join(campaign, "monitor-status.json")))
if %w[complete needs_review unexpected_stop].include?(status.fetch("monitor_health"))
  puts "Periodic checks stopped at #{status.fetch('monitor_health')}; inspect campaign records before resuming."
  system("systemctl", "--user", "stop", manifest.fetch("monitor_timer"))
end
