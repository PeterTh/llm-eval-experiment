# frozen_string_literal: true
require_relative 'shape_full'
require 'rbconfig'

if $PROGRAM_NAME == __FILE__
  raise 'Usage: launch_shape_full.rb WORKSPACE EVIDENCE UNIT' unless ARGV.size == 3
  workspace, evidence, unit = ARGV
  raise 'Unexpected service name' unless unit.match?(/\Allm-validation-shape-topology-\d{8}(?:-\d+)?\z/)
  campaign = ValidationAudit::FullShapeCampaign.new(workspace: workspace, evidence: evidence)
  campaign.verify_inputs!
  pids, _, pstatus = Open3.capture3('pgrep', '-u', 'llmtest')
  raise 'Generation account is active' unless pstatus.exitstatus == 1 && pids.empty?
  status, errors, result = Open3.capture3('systemctl', '--user', 'show', unit + '.service', '--property=ActiveState', '--value')
  raise "Cannot inspect service: #{errors}" unless result.success?
  raise 'Sweep service already active' if %w[active activating deactivating].include?(status.strip)
  raise 'Stop guard exists' if File.exist?(File.join(evidence, 'STOP-shape-topology-full'))
  raise 'Concurrency failure needs investigation' if File.exist?(File.join(evidence, 'CONCURRENCY-REVIEW.json'))
  launch_number = Dir[File.join(evidence, 'shape-topology-full-launch-*.json')].size + 1
  log = File.join(evidence, 'shape-topology-full-service.log')
  inherited = %w[PATH LD_LIBRARY_PATH LIBRARY_PATH CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH PKG_CONFIG_PATH CMAKE_PREFIX_PATH LANG LC_ALL LC_CTYPE]
    .filter_map { |key| "#{key}=#{ENV.fetch(key)}" if ENV.key?(key) }
  command = ['systemd-run', '--user', '--collect', "--unit=#{unit}", '--description=Supplemental correctness validation; no performance benchmarks',
    '--property=Type=exec', '--property=Restart=no', '--property=KillMode=mixed', '--property=TimeoutStopSec=45s',
    "--property=WorkingDirectory=#{File.expand_path('../..', __dir__)}", "--property=StandardOutput=append:#{log}", '--property=StandardError=inherit',
    '/usr/bin/env', *inherited, RbConfig.ruby, File.join(__dir__, 'shape_full.rb'), File.realpath(workspace), File.expand_path(evidence), 'run']
  started = Time.now.utc.iso8601
  output, error, launched = Open3.capture3(*command)
  receipt = { 'unit' => unit + '.service', 'started_at' => started, 'command' => command,
    'success' => launched.success?, 'stdout' => output, 'stderr' => error,
    'authorization_sha256' => ValidationAudit.sha(File.join(evidence, ValidationAudit::FullShapeCampaign::APPROVAL_FILE)),
    'driver_sha256' => ValidationAudit.sha(File.join(__dir__, 'shape_full.rb')), 'benchmark_runs' => 0 }
  ValidationAudit.save(File.join(evidence, format('shape-topology-full-launch-%04d.json', launch_number)), receipt)
  raise "Launch failed: #{error}" unless launched.success?
  puts JSON.pretty_generate(receipt.slice('unit', 'started_at', 'success', 'benchmark_runs'))
end
