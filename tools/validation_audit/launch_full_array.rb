# frozen_string_literal: true
require_relative 'full_array_full'

raise 'Usage: launch_full_array.rb WORKSPACE EVIDENCE UNIT' unless ARGV.size == 3
workspace, evidence, unit = ARGV
raise 'Unexpected service name' unless unit.match?(/\Allm-validation-full-array-\d{8}(?:-\d+)?\z/)
campaign = ValidationAudit::FullArrayFull.new(workspace: workspace, evidence: evidence)
campaign.prepare
pids, _, pstatus = Open3.capture3('pgrep', '-u', 'llmtest')
raise 'Generation account is active' unless pstatus.exitstatus == 1 && pids.empty?
state, errors, status = Open3.capture3('systemctl', '--user', 'show', unit + '.service', '--property=ActiveState', '--value')
raise errors unless status.success?
raise 'Sweep already active' if %w[active activating deactivating].include?(state.strip)
raise 'Stop guard exists' if File.exist?(File.join(evidence, 'STOP-full-array-full'))
root = File.join(evidence, ValidationAudit::FullArrayFull::PHASE)
number = Dir[File.join(root, 'launch-*.json')].size + 1
log = File.join(root, 'service.log')
environment = %w[PATH LD_LIBRARY_PATH LIBRARY_PATH CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH PKG_CONFIG_PATH CMAKE_PREFIX_PATH LANG LC_ALL LC_CTYPE]
  .filter_map { |key| "#{key}=#{ENV.fetch(key)}" if ENV.key?(key) }
command = ['systemd-run', '--user', '--collect', "--unit=#{unit}", '--description=Full-array correctness validation; no performance measurements or LLM calls',
  '--property=Type=exec', '--property=Restart=no', '--property=KillMode=mixed', '--property=TimeoutStopSec=45s',
  "--property=WorkingDirectory=#{File.expand_path('../..', __dir__)}", "--property=StandardOutput=append:#{log}", '--property=StandardError=inherit',
  '/usr/bin/env', *environment, RbConfig.ruby, File.join(__dir__, 'full_array_full.rb'), File.realpath(workspace), File.realpath(evidence), 'run']
output, error, launched = Open3.capture3(*command)
receipt = { 'unit' => unit + '.service', 'started_at' => Time.now.utc.iso8601, 'command' => command,
  'success' => launched.success?, 'stdout' => output, 'stderr' => error,
  'authorization_sha256' => campaign.plan.fetch('authorization_sha256'), 'plan_sha256' => ValidationAudit.sha(File.join(root, 'plan.json')),
  'launcher_sha256' => ValidationAudit.sha(__FILE__), 'benchmark_runs' => 0, 'llm_invocations' => 0 }
ValidationAudit.save(File.join(root, format('launch-%04d.json', number)), receipt)
raise "Launch failed: #{error}" unless launched.success?
puts JSON.pretty_generate(receipt.slice('unit', 'started_at', 'success', 'benchmark_runs', 'llm_invocations'))
