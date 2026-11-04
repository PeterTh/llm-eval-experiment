# frozen_string_literal: true
require_relative 'inventory'
require_relative '../../lib/local_evaluation/comparison_policy'

module ValidationAudit
  class Runner
    attr_reader :workspace, :evidence
    def initialize(workspace:, evidence:)
      @workspace = File.realpath(workspace)
      raise 'Executions/builds must stay on local /tmp' unless @workspace.start_with?('/tmp/')
      @evidence = File.expand_path(evidence)
      @runner = LocalEvaluation::ProcessRunner.new
      @resources = LocalEvaluation::Resources.new
      @cache_paths = Dir['/home/petert/llm_para_local_evaluation/*/{validation,benchmark}/*'].select { |d| File.directory?(d) }.group_by { |d| File.basename(d) }
    end

    def with_host
      pids, _, status = Open3.capture3('pgrep', '-u', 'llmtest')
      raise 'Generation account has active processes' unless status.exitstatus == 1 && pids.empty?
      lock = LocalEvaluation::HostPerformanceLock.new
      @resources.verify_topology!
      yield
    ensure
      lock&.close
    end

    def cache_for(row)
      expected = row.fetch('source_files').transform_values { |v| v.fetch('sha256') }
      candidates = if row.fetch('backend') == 'sequential'
        Dir["/home/petert/llm_para_local_evaluation/*/validation/reference/#{row.fetch('benchmark')}"]
      else
        @cache_paths.fetch(row.fetch('id'), [])
      end
      candidates.sort.reverse_each do |directory|
        binary = File.join(directory, row.fetch('benchmark').tr('-', '_'))
        next unless File.file?(binary) && File.executable?(binary)
        next unless %w[build cmake].all? { |s| File.file?("#{directory}/#{s}_exitcode.log") && File.read("#{directory}/#{s}_exitcode.log").strip == '0' }
        next unless File.file?("#{directory}/source_staging.yaml")
        next unless LocalEvaluation.load_yaml("#{directory}/source_staging.yaml").fetch('content_sha256') == row.fetch('staged_source_sha256')
        source = "#{directory}/source"
        actual = Dir["#{source}/**/*"].select { |p| File.file?(p) && !File.symlink?(p) }.to_h { |p| [p.delete_prefix(source + '/'), ValidationAudit.sha(p)] }
        next unless actual == expected && File.mtime(binary) <= File.mtime("#{directory}/build_exitcode.log")
        return { 'directory' => directory, 'executable' => binary, 'binary_sha256' => ValidationAudit.sha(binary),
          'receipts' => %w[source_staging.yaml cmake_command.log cmake_exitcode.log build_command.log build_exitcode.log].to_h { |p| [p, ValidationAudit.sha("#{directory}/#{p}")] } }
      end
      nil
    end

    def binary_for(row)
      directory = File.join(@workspace, 'build', row.fetch('id'))
      binding = File.join(directory, 'binding.json')
      if File.file?(binding)
        saved = ValidationAudit.read(binding)
        raise 'Local binary binding changed' unless saved.fetch('source_files') == row.fetch('source_files') &&
          ValidationAudit.sha(saved.fetch('executable')) == saved.fetch('binary_sha256')
        return saved
      end
      FileUtils.mkdir_p(directory)
      executable = File.join(directory, row.fetch('benchmark').tr('-', '_'))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cache = cache_for(row)
      if cache
        FileUtils.cp(cache.fetch('executable'), executable, preserve: true)
        raise 'Cached executable changed during copy' unless ValidationAudit.sha(executable) == cache.fetch('binary_sha256')
      else
        source = File.join(directory, 'source')
        repository = row.fetch('backend') == 'sequential' ? INPUT : SOURCE
        row.fetch('source_files').each do |path, pin|
          bytes = ValidationAudit.git(repository, 'cat-file', 'blob', pin.fetch('git_blob'))
          raise 'Git source changed' unless Digest::SHA256.hexdigest(bytes) == pin.fetch('sha256')
          destination = File.join(source, path)
          FileUtils.mkdir_p(File.dirname(destination))
          File.binwrite(destination, bytes)
          File.chmod(pin.fetch('mode').to_i(8) & 0o777, destination)
        end
        success, error = LocalEvaluation::BuildSupport.build(source_dir: File.join(source, row.fetch('benchmark')),
          build_dir: directory, runner: @runner, par_type: row.fetch('backend'))
        raise LocalEvaluation::InfrastructureError, "Cannot reproduce prior successful build #{row.fetch('id')}: #{error}" unless success
      end
      value = { 'id' => row.fetch('id'), 'source_files' => row.fetch('source_files'), 'executable' => executable,
        'binary_sha256' => ValidationAudit.sha(executable), 'reused_cache' => cache,
        'preparation_seconds' => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started }
      ValidationAudit.save(binding, value)
      ValidationAudit.save(File.join(@evidence, 'bindings', "#{row.fetch('id')}.json"), value)
      value
    end

    def check(row, definition, reference: nil)
      destination = File.join(@evidence, definition.fetch('id'), row.fetch('id'))
      if File.file?("#{destination}/result.json")
        result = ValidationAudit.read("#{destination}/result.json")
        raise 'Cannot reuse changed case/source' unless result.fetch('source_commit') == row.fetch('source_commit') && result.fetch('definition') == definition
        return result
      end
      binding = binary_for(row)
      executable = binding.fetch('executable')
      args = definition.fetch('args')
      topology = definition.fetch('topology', 'validation')
      mode = topology == 'measurement' ? :benchmark : :validation
      env, argv = if row.fetch('backend') == 'sequential'
        [{ 'CUDA_VISIBLE_DEVICES' => '', 'OMP_NUM_THREADS' => '1' }, [executable, *args]]
      else
        @resources.command(par_type: row.fetch('backend'), executable: executable, args: args, mode: mode)
      end
      limits = mode == :benchmark ? LocalEvaluation::ExecutionLimits::PERFORMANCE : LocalEvaluation::ExecutionLimits::VALIDATION
      execution = @runner.run(argv: argv, env: env, prefix: "#{destination}/validation", chdir: File.dirname(executable),
        timeout: definition.fetch('timeout', 30), limits: limits)
      output = File.read("#{destination}/validation_stdout.log")
      internal = output.include?('Validation: PASSED') && !output.include?('Validation: FAILED') && !output.include?('Validation fail')
      comparison = if !execution.success
        [false, "Supplemental correctness execution failed: exit #{execution.exit_code}, timeout #{execution.timed_out}."]
      elsif !internal
        [false, 'Supplemental internal check failed.']
      elsif reference
        numerical = validate(reference, output, row.fetch('benchmark'))
        numerical.first && definition['comparison'] == 'integer_hash' ? LocalEvaluation::ComparisonPolicy.integer_hashes(reference, output) : numerical
      else
        [true, 'Sequential reference completed its internal checks.']
      end
      result = { 'id' => row.fetch('id'), 'source_commit' => row.fetch('source_commit'), 'source_path' => row.fetch('source_path'),
        'definition' => definition, 'binary_sha256' => binding.fetch('binary_sha256'), 'execution' => execution.to_h,
        'internal_validation' => internal, 'comparison' => comparison, 'passed' => comparison.first,
        'reference_sha256' => reference && Digest::SHA256.hexdigest(reference), 'output_sha256' => Digest::SHA256.hexdigest(output),
        'checked_at' => Time.now.utc.iso8601, 'performance_measurement' => false }
      ValidationAudit.save("#{destination}/result.json", result)
      result
    end
  end
end
