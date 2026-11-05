# frozen_string_literal: true
require_relative 'full_array_execution_failure'

raise 'Usage: launch_full_array_execution_review.rb WORKSPACE EVIDENCE UNIT' unless ARGV.size == 3
workspace, evidence, unit = ARGV
raise 'Unexpected service name' unless unit.match?(/\Allm-validation-full-array-\d{8}(?:-\d+)?\z/)
root = File.join(evidence, ValidationAudit::FullArrayFull::PHASE)
plan = ValidationAudit.read(File.join(root, 'plan.json'))
campaign = ValidationAudit::FullArrayFull.new(workspace: workspace, evidence: evidence)
raise 'Frozen base runtime changed' unless campaign.method_files == plan.fetch('method_sha256')
entry = File.join(__dir__, 'full_array_execution_failure.rb')
review_paths = {
  'primary_output_review' => File.join(root, ValidationAudit::FullArrayReviewedOutputs::ID, 'primary-output-review.json'),
  'suppressed_output_review' => File.join(root, ValidationAudit::FullArraySuppressedOutputs::ID, 'suppressed-output-review.json'),
  'execution_failure_review' => File.join(root, ValidationAudit::FullArrayExecutionReviewPolicy::ID, 'execution-failure-review.json') }
review_paths.each_value do |path|
  review = ValidationAudit.read(path)
  method_name = File.basename(review.fetch('extension_method'))
  raise 'Reviewed extension changed' unless review.fetch('extension_method_sha256') == ValidationAudit.sha(File.join(__dir__, method_name))
end
root_reviews = Dir[File.join(root, '*', 'root-output-review.json')].sort.to_h do |path|
  review = ValidationAudit.read(path)
  raise 'Root-output extension changed' unless review.fetch('extension_method_sha256') == ValidationAudit.sha(File.join(__dir__, 'full_array_root_output_reviews.rb'))
  [review.fetch('id'), ValidationAudit.sha(path)]
end
raise 'No source-bound root-output reviews' if root_reviews.empty?
pids, _, pstatus = Open3.capture3('pgrep', '-u', 'llmtest')
raise 'Generation account is active' unless pstatus.exitstatus == 1 && pids.empty?
state, errors, status = Open3.capture3('systemctl', '--user', 'show', unit + '.service', '--property=ActiveState', '--value')
raise errors unless status.success?
raise 'Sweep already active' if %w[active activating deactivating].include?(state.strip)
raise 'Stop guard exists' if File.exist?(File.join(evidence, 'STOP-full-array-full'))
raise 'Sweep already complete' if File.exist?(File.join(root, 'completion.json'))
number = Dir[File.join(root, 'launch-*.json')].size + 1
environment = %w[PATH LD_LIBRARY_PATH LIBRARY_PATH CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH PKG_CONFIG_PATH CMAKE_PREFIX_PATH LANG LC_ALL LC_CTYPE]
  .filter_map { |key| "#{key}=#{ENV.fetch(key)}" if ENV.key?(key) }
command = ['systemd-run', '--user', '--collect', "--unit=#{unit}", '--description=Full-array correctness sweep with retained source-bound reviews',
  '--property=Type=exec', '--property=Restart=no', '--property=KillMode=mixed', '--property=TimeoutStopSec=45s',
  "--property=WorkingDirectory=#{File.expand_path('../..', __dir__)}", "--property=StandardOutput=append:#{File.join(root, 'service.log')}",
  '--property=StandardError=inherit', '/usr/bin/env', *environment, RbConfig.ruby, entry,
  File.realpath(workspace), File.realpath(evidence), 'run']
output, error, launched = Open3.capture3(*command)
receipt = { 'unit' => unit + '.service', 'started_at' => Time.now.utc.iso8601, 'command' => command,
  'success' => launched.success?, 'stdout' => output, 'stderr' => error,
  'authorization_sha256' => plan.fetch('authorization_sha256'), 'plan_sha256' => ValidationAudit.sha(File.join(root, 'plan.json')),
  'launcher_sha256' => ValidationAudit.sha(__FILE__), 'extension_method_sha256' => ValidationAudit.sha(entry),
  'entrypoint' => File.basename(entry), 'launcher_name' => File.basename(__FILE__),
  'reviews_sha256' => review_paths.transform_values { |path| ValidationAudit.sha(path) },
  'root_output_reviews' => root_reviews, 'benchmark_runs' => 0, 'llm_invocations' => 0 }
ValidationAudit.save(File.join(root, format('launch-%04d.json', number)), receipt)
raise "Launch failed: #{error}" unless launched.success?
puts JSON.pretty_generate(receipt.slice('unit', 'started_at', 'success', 'extension_method_sha256', 'benchmark_runs', 'llm_invocations'))
