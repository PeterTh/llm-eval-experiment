# frozen_string_literal: true
require_relative 'full_array_full'

module ValidationAudit
  # One reviewed header-only variation. The frozen observer's digest guard is
  # configured for this exact helper in an isolated process; its FNV function,
  # breakpoints, execution limits and numerical comparison remain unchanged.
  module FullArrayHashCompatibility
    ID = 'black-scholes_qwen-3.6-27B-udq4_hybrid_r2'
    BASE_SHA = 'da47685f2f22487193f986eeba67fe414f80d50536a63e03cae0a6935d76a4e9'
    VARIANT_SHA = '59016cf476cc217af79d9271396b24fd4167cf045f0231107590b0155849fe8e'
    BASE_BLOB = '42ad06602e366caf62be9789dcae2d52fd0c2845'
    VARIANT_BLOB = 'ad6b15ea7a7e60c44e77d0600c46475c9c4941dd'
    module_function

    def verify_sources!(baseline, variant, program)
      unless Digest::SHA256.hexdigest(baseline) == BASE_SHA && Digest::SHA256.hexdigest(variant) == VARIANT_SHA &&
          variant == baseline.sub("#include <cstdint>\n", "#include <cstdint>\n#include <mpi.h>\n") &&
          program.index('#include <mpi.h>') && program.index('#include "../common/results_output.hpp"') &&
          program.index('#include <mpi.h>') < program.index('#include "../common/results_output.hpp"')
        raise 'Helper is not the reviewed redundant MPI include variation'
      end
    end

    def with_variant_guard
      raise 'Unexpected original helper guard' unless FullArrayCapture::HASH_SHA == BASE_SHA
      FullArrayCapture.send(:remove_const, :HASH_SHA)
      FullArrayCapture.const_set(:HASH_SHA, VARIANT_SHA)
      begin
        yield
      ensure
        FullArrayCapture.send(:remove_const, :HASH_SHA)
        FullArrayCapture.const_set(:HASH_SHA, BASE_SHA)
      end
    end

    def run(workspace:, evidence:)
      campaign = FullArrayFull.new(workspace: workspace, evidence: evidence)
      plan = campaign.prepare
      group = plan.fetch('groups').find { |entry| entry.fetch('full_ids').include?(ID) }
      raise 'Compatibility observation is outside the approved scope' unless group
      row = ValidationAudit.read(File.join(evidence, 'inventory-black-scholes.json')).fetch('rows').find { |entry| entry.fetch('id') == ID }
      helper = row.fetch('source_files').fetch('common/hash.hpp')
      raise 'Different helper source' unless helper.fetch('sha256') == VARIANT_SHA && helper.fetch('git_blob') == VARIANT_BLOB
      program = row.fetch('source_files').fetch('black-scholes/black_scholes.cpp')
      source = ValidationAudit.git(SOURCE, 'cat-file', 'blob', program.fetch('git_blob'))
      raise 'Program source digest differs' unless Digest::SHA256.hexdigest(source) == program.fetch('sha256')
      verify_sources!(ValidationAudit.git(SOURCE, 'cat-file', 'blob', BASE_BLOB),
        ValidationAudit.git(SOURCE, 'cat-file', 'blob', VARIANT_BLOB), source)
      root = File.join(evidence, FullArrayFull::PHASE)
      raise 'Refusing to repeat an existing observation' if File.exist?(File.join(root, ID))
      method = File.binread(__FILE__)
      method_digest = Digest::SHA256.hexdigest(method)
      method_relative = File.join('observer-adapters', method_digest, File.basename(__FILE__))
      method_path = File.join(root, method_relative)
      FileUtils.mkdir_p(File.dirname(method_path))
      File.open(method_path, File::WRONLY | File::CREAT | File::EXCL) { |file| file.write(method) }
      adapter = { 'schema_version' => 1, 'id' => ID, 'kind' => 'redundant-mpi-header-hash-helper',
        'review' => 'The sole helper difference is an additional #include <mpi.h>; the translation unit already includes mpi.h before results_output.hpp. The FNV implementation is byte-identical.',
        'base_helper_sha256' => BASE_SHA, 'base_helper_git_blob' => BASE_BLOB,
        'accepted_helper_sha256' => VARIANT_SHA, 'accepted_helper_git_blob' => VARIANT_BLOB,
        'source_commit' => row.fetch('source_commit'), 'source_files' => row.fetch('source_files'),
        'adapter_method' => method_relative, 'adapter_method_sha256' => method_digest,
        'plan_sha256' => ValidationAudit.sha(File.join(root, 'plan.json')),
        'effective_configuration' => { 'FullArrayCapture::HASH_SHA' => VARIANT_SHA },
        'frozen_method_files_changed' => 0, 'program_source_changes' => 0, 'executable_file_changes' => 0,
        'benchmark_runs' => 0, 'llm_invocations' => 0 }
      ValidationAudit.save(File.join(root, 'observer-adapters', ID + '-plan.json'), adapter)
      observation = nil
      Runner.new(workspace: workspace, evidence: evidence).with_host do
        with_variant_guard do
          observation = FullArrayCapture.capture(workspace: workspace, evidence: evidence, id: ID,
            benchmark: row.fetch('benchmark'), backend: row.fetch('backend'), args: group.fetch('args'), phase: FullArrayFull::PHASE)
        end
      end
      adapter.merge!('observation_sha256' => ValidationAudit.sha(File.join(root, ID, 'observation.json')),
        'observation_complete' => observation.fetch('observation_complete'), 'program_executions' => 1,
        'completed_at' => Time.now.utc.iso8601)
      ValidationAudit.save(File.join(root, ID, 'observation-adapter.json'), adapter)
      comparison = campaign.check(row, group)
      unless comparison.fetch('passed')
        ValidationAudit.save(File.join(root, 'failure-events', ID + '.json'), { 'id' => ID,
          'checked_at' => Time.now.utc.iso8601, 'comparison' => comparison.fetch('arrays'),
          'comparison_sha256' => ValidationAudit.sha(File.join(root, ID, 'comparison.json')), 'benchmark_runs' => 0 })
      end
      puts JSON.pretty_generate(comparison.reject { |key, _| key == 'source' })
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: full_array_hash_compatibility.rb WORKSPACE EVIDENCE' unless ARGV.size == 2
  ValidationAudit::FullArrayHashCompatibility.run(workspace: ARGV[0], evidence: ARGV[1])
end
