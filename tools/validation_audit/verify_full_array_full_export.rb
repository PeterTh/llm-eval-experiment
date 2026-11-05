# frozen_string_literal: true
require_relative 'full_array_offline_support'
require_relative 'verify_full_array_pilot_export'
require_relative 'full_array_eligibility'
require_relative 'full_array_execution_review_policy'

module ValidationAudit
  # Offline integrity verification, not a new program execution. Complete
  # failure arrays permit replay of exclusions. Passing full-array comparisons
  # remain bound reports: their bulk arrays are deliberately not republished.
  module FullArrayFullVerification
    module_function

    def safe_path(root, relative)
      raise 'Unsafe evidence path' unless relative.is_a?(String) && !relative.empty? &&
        !relative.start_with?('/') && relative.split('/').none? { |part| ['', '.', '..'].include?(part) }
      path = File.join(root, relative)
      raise 'Evidence symlink or missing member' unless File.file?(path) && !File.symlink?(path) &&
        File.realpath(path).start_with?(File.realpath(root) + '/')
      path
    end

    def checked_members(root, receipt)
      names = receipt.fetch('files_sha256').keys
      raise 'Receipt includes itself' if names.include?('export.json')
      names.each do |relative|
        raise "Evidence member changed: #{relative}" unless FullArrayOffline.sha(safe_path(root, relative)) == receipt.fetch('files_sha256').fetch(relative)
      end
      actual = Dir[File.join(root, '**/*')].select { |path| File.file?(path) || File.symlink?(path) }
        .map { |path| path.delete_prefix(root + '/') }.sort
      raise 'Unpinned export members' unless actual == (names + ['export.json']).sort
      raise 'Retention size differs' unless names.sum { |name| File.size(File.join(root, name)) } == receipt.fetch('retained_bytes')
    end

    def normalized_objects(record)
      observation = record.fetch('observation')
      objects = observation.fetch('objects')
      stdout = record.fetch('logs').fetch('stdout')
      printed = FullArrayOffline.output_objects(stdout)
      raise 'Printed-object metadata differs' unless observation.fetch('printed_objects') == printed && !printed.empty?
      key = ->(object) { object.slice('name', 'elements', 'fnv1a64') }
      identity_keys = %w[name dtype elements bytes sha256 fnv1a64]
      groups = objects.group_by { |object| object.fetch('name') }
      duplicate = groups.values.any? { |group| group.size > 1 }
      if observation.fetch('observation_complete') && !duplicate
        raise 'Complete observation has errors or an unnecessary reconciliation' unless observation.fetch('errors').empty? && !record.key?('capture_reconciliation')
        raise 'Captured/printed objects differ' unless objects.map(&key).sort_by(&:to_s) == printed.sort_by(&:to_s)
        return objects
      end
      review = record.fetch('capture_reconciliation')
      raise 'Reconciliation digest differs' unless FullArrayOffline.json_digest(review) == record.fetch('comparison').fetch('observation_reconciliation_sha256')
      if [FullArrayOffline::SUPPRESSED_KIND, FullArrayOffline::ROOT_OUTPUT_KIND].include?(review['kind'])
        review_key = review['kind'] == FullArrayOffline::SUPPRESSED_KIND ? 'suppressed_output_review' : 'root_output_review'
        suppression = record.fetch(review_key)
        selected = suppression.fetch('selected_objects')
        matches = objects.select { |object| key.call(object) == printed.first }
        unless !observation.fetch('observation_complete') &&
            observation.fetch('errors') == ['Captured arrays do not match all printed result objects'] &&
            printed.size == 1 && matches.size == 1 && selected == matches && selected.first.fetch('rank') == 'rank-0' &&
            selected == review.fetch('selected_objects') &&
            FullArrayOffline.json_digest(suppression) == record.fetch(review_key + '_sha256') &&
            record.fetch(review_key + '_sha256') == review.fetch(review_key + '_sha256') &&
            suppression.fetch('original_observation_sha256') == record.fetch('comparison').fetch('observation_sha256') &&
            suppression.fetch('id') == record.fetch('id') && suppression.fetch('kind') == review.fetch('kind')
          raise 'Suppressed partial captures are not bound to the unique printed root result'
        end
        return selected
      end
      if review['kind'] == FullArrayOffline::REVIEW_KIND
        primary = record.fetch('primary_output_review')
        selected = primary.fetch('selected_objects')
        unless observation.fetch('observation_complete') && observation.fetch('errors').empty? &&
            printed.map { |object| object.fetch('name') }.uniq.size == 1 &&
            objects.map(&key).tally == printed.tally && selected.size == 1 && objects.include?(selected.first) &&
            key.call(selected.first) == printed.first && selected == review.fetch('selected_objects') &&
            FullArrayOffline.json_digest(primary) == record.fetch('primary_output_review_sha256') &&
            record.fetch('primary_output_review_sha256') == review.fetch('primary_output_review_sha256') &&
            primary.fetch('original_observation_sha256') == record.fetch('comparison').fetch('observation_sha256') &&
            primary.fetch('id') == record.fetch('id') && primary.fetch('kind') == FullArrayOffline::REVIEW_KIND &&
            record.fetch('comparison').fetch('passed') == false
          raise 'Primary printed result is not unambiguously bound to the reviewed failure'
        end
        return selected
      end
      unless review.fetch('id') == record.fetch('id') &&
          review.fetch('original_observation_sha256') == record.fetch('comparison').fetch('observation_sha256') &&
          review.fetch('program_runs').zero? && review.fetch('benchmark_runs').zero? &&
          (observation.fetch('errors') - ['Captured arrays do not match all printed result objects']).empty? &&
          groups.values.all? { |group| group.map { |o| o.slice(*identity_keys) }.uniq.size == 1 } &&
          objects.map(&key).uniq.sort_by(&:to_s) == printed.uniq.sort_by(&:to_s)
        raise 'Observation cannot be reconciled as identical complete replicas'
      end
      selected = review.fetch('selected_objects')
      unless review.fetch('captured_objects') == objects.size && selected.size == groups.size &&
          selected.map { |object| object.fetch('name') }.sort == groups.keys.sort && selected.all? { |object| objects.include?(object) }
        raise 'Reconciliation selected a missing or incomplete replica'
      end
      selected
    end

    def witness(root, relative)
      raise 'Unexpected witness location' unless relative.match?(%r{\Afailure-arrays/[a-f0-9]{64}\.json\z})
      value = FullArrayOffline.read(safe_path(root, relative))
      hex = value.fetch('values_hex')
      raise 'Malformed witness bytes' unless hex.match?(/\A(?:[a-f0-9]{2})*\z/)
      bytes = [hex].pack('H*')
      type = FullArrayOffline::SYMBOLS.values.find { |entry| entry.first == value.fetch('dtype') }
      unless type && value.fetch('sha256') == File.basename(relative, '.json') &&
          bytes.bytesize == value.fetch('bytes') && bytes.bytesize == value.fetch('elements') * type[1] &&
          Digest::SHA256.hexdigest(bytes) == value.fetch('sha256') &&
          (bytes.empty? ? nil : FullArrayOffline.fnv(bytes)) == value.fetch('fnv1a64')
        raise 'Witness content or scalar layout differs'
      end
      [value, bytes.unpack(type[2])]
    end

    def tolerance(reference, benchmark)
      return 0 if reference.fetch('dtype').start_with?('i', 'u')
      benchmark == 'roomsim' && reference.fetch('name').include?('Distance') ? 5.0 : 1e-5
    end

    def verify_helper!(record, root)
      source = record.fetch('comparison').fetch('source')
      helper = source.fetch('source_files').fetch('common/hash.hpp')
      if helper.fetch('sha256') == FullArrayOffline::HASH_SHA
        raise 'Unnecessary observation adapter' if record.key?('observation_adapter')
        return
      end
      adapter = record.fetch('observation_adapter')
      method = safe_path(root, adapter.fetch('adapter_method'))
      unless record.fetch('id') == 'black-scholes_qwen-3.6-27B-udq4_hybrid_r2' &&
          helper.fetch('sha256') == '59016cf476cc217af79d9271396b24fd4167cf045f0231107590b0155849fe8e' &&
          helper.fetch('git_blob') == 'ad6b15ea7a7e60c44e77d0600c46475c9c4941dd' &&
          adapter.fetch('schema_version') == 1 && adapter.fetch('id') == record.fetch('id') &&
          adapter.fetch('kind') == 'redundant-mpi-header-hash-helper' &&
          adapter.fetch('base_helper_sha256') == FullArrayOffline::HASH_SHA &&
          adapter.fetch('base_helper_git_blob') == '42ad06602e366caf62be9789dcae2d52fd0c2845' &&
          adapter.fetch('accepted_helper_sha256') == helper.fetch('sha256') &&
          adapter.fetch('accepted_helper_git_blob') == helper.fetch('git_blob') &&
          adapter.fetch('source_commit') == source.fetch('source_commit') && adapter.fetch('source_files') == source.fetch('source_files') &&
          adapter.fetch('effective_configuration') == { 'FullArrayCapture::HASH_SHA' => helper.fetch('sha256') } &&
          adapter.fetch('observation_sha256') == record.fetch('comparison').fetch('observation_sha256') &&
          adapter.fetch('observation_complete') == record.fetch('observation').fetch('observation_complete') &&
          adapter.fetch('program_executions') == 1 &&
          %w[frozen_method_files_changed program_source_changes executable_file_changes benchmark_runs llm_invocations].all? { |key| adapter.fetch(key).zero? } &&
          FullArrayOffline.json_digest(adapter) == record.fetch('observation_adapter_sha256') &&
          FullArrayOffline.sha(method) == adapter.fetch('adapter_method_sha256')
        raise 'Unreviewed or mismatched hash-helper compatibility adapter'
      end
    end

    def verify_primary_review!(record, reference, root)
      return unless record.key?('primary_output_review')
      review = record.fetch('primary_output_review')
      source = record.fetch('comparison').fetch('source')
      observation = record.fetch('observation')
      unless record.fetch('id') == FullArrayOffline::REVIEW_ID && review.fetch('schema_version') == 1 &&
          review.fetch('source_commit') == source.fetch('source_commit') && review.fetch('source_path') == source.fetch('source_path') &&
          review.fetch('source_file') == source.fetch('source_files').fetch('roomsim/roomsim.cpp') &&
          review.fetch('source_file').fetch('git_blob') == '503bc397f4526c54baf3ed44a5111ee8ea2c172d' &&
          review.fetch('source_file').fetch('sha256') == '8053fb6c27bf55cdf3ee8960f72a7dd059ab168aa2ec73647fd7af7c020bf3bb' &&
          review.fetch('stdout_sha256') == observation.fetch('stdout_sha256') &&
          review.fetch('reference_observation_sha256') == reference.fetch('observation_sha256') &&
          review.fetch('extension_method_sha256') == record.fetch('capture_reconciliation').fetch('extension_method_sha256') &&
          FullArrayOffline.sha(safe_path(root, review.fetch('extension_method'))) == review.fetch('extension_method_sha256') &&
          %w[program_runs benchmark_runs llm_invocations program_source_changes].all? { |key| review.fetch(key).zero? }
        raise 'Primary-output review source or method differs'
      end
      printed = observation.fetch('printed_objects')
      checks = review.fetch('ordered_comparisons')
      unless checks.size == printed.size && review.fetch('captured_objects') == observation.fetch('objects').size &&
          record.fetch('reviewed_replica_arrays').keys.sort == observation.fetch('objects').map { |object| object.fetch('sha256') }.uniq.sort
        raise 'Reviewed replica coverage differs'
      end
      left = reference.fetch('observation').fetch('objects').fetch(0)
      ref_owner = reference.fetch('observation').fetch('id')
      ref_data, ref_values = witness(root, record.fetch('failure_arrays').fetch(ref_owner).fetch(left.fetch('name')))
      raise 'Reviewed reference bytes differ' unless ref_data.fetch('sha256') == left.fetch('sha256')
      printed.zip(checks).each do |output, check|
        right = observation.fetch('objects').find do |object|
          object.slice('name', 'elements', 'fnv1a64') == output && object.fetch('rank') == check.fetch('rank') &&
            object.fetch('sha256') == check.fetch('array_sha256')
        end
        raise 'Reviewed printed replica is missing' unless right
        data, values = witness(root, record.fetch('reviewed_replica_arrays').fetch(right.fetch('sha256')))
        unless data.slice('dtype', 'elements', 'bytes', 'sha256', 'fnv1a64') == right.slice('dtype', 'elements', 'bytes', 'sha256', 'fnv1a64')
          raise 'Reviewed replica bytes differ'
        end
        result = FullArrayOffline.compare_values(ref_values, values, epsilon: tolerance(left, source.fetch('benchmark')))
          .merge('name' => left.fetch('name'), 'reference_array_sha256' => left.fetch('sha256'), 'actual_array_sha256' => right.fetch('sha256'))
        comparison = check.fetch('comparison')
        unless comparison.fetch('id') == record.fetch('id') && comparison.fetch('arrays') == [result] &&
            comparison.fetch('passed') == result.fetch('mismatches').zero? && comparison.fetch('benchmark_runs').zero?
          raise 'Complete reviewed replica comparison does not reproduce'
        end
      end
      raise 'Reviewed primary output is not a failure' unless checks.first.dig('comparison', 'passed') == false
    end

    def verify_record!(record, reference, group, root, expected_method: nil)
      id, comparison, observation, logs = record.values_at('id', 'comparison', 'observation', 'logs')
      source = comparison.fetch('source')
      benchmark, backend = group.values_at('benchmark', 'backend')
      if expected_method && observation.fetch('method_sha256') != expected_method
        raise 'Observation method differs from the frozen sweep'
      end
      unless record.fetch('phase') == FullArrayOffline::PHASE && id == comparison.fetch('id') && id == observation.fetch('id') &&
          id == source.fetch('id') && source.fetch('benchmark') == benchmark && source.fetch('backend') == backend &&
          observation.fetch('benchmark') == benchmark && observation.fetch('backend') == backend &&
          observation.fetch('args') == group.fetch('args') &&
          FullArrayOffline.json_digest(comparison) == record.fetch('comparison_sha256') &&
          FullArrayOffline.json_digest(observation) == comparison.fetch('observation_sha256') &&
          comparison.fetch('reference_observation_sha256') == reference.fetch('observation_sha256') &&
          logs.keys.sort == %w[command exitcode stderr stdout wall_time] &&
          logs.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) } == record.fetch('log_sha256') &&
          Digest::SHA256.hexdigest(logs.fetch('stdout')) == observation.fetch('stdout_sha256')
        raise "Full-array record identity or digest differs: #{id}"
      end
      binding = FullArrayOffline.expand_binding(record.fetch('binding'), source)
      unless binding.fetch('id') == id && binding.fetch('binary_sha256') == observation.fetch('binary_sha256') &&
          FullArrayOffline.json_digest(binding) == observation.fetch('binding_sha256')
        raise 'Full-array executable/source binding differs'
      end
      verify_helper!(record, root)
      return verify_execution_review!(record, root) if record.key?('execution_failure_review')
      execution = observation.fetch('execution')
      unless execution.fetch('success') && execution.fetch('exit_code') == 0 && !execution.fetch('timed_out') &&
          !execution.fetch('output_truncated') && logs.fetch('exitcode').strip == '0' &&
          execution.fetch('argv').last(group.fetch('args').size) == group.fetch('args') &&
          logs.fetch('stdout').include?('Validation: PASSED') && !logs.fetch('stdout').include?('Validation: FAILED') &&
          !logs.fetch('stdout').include?('Validation fail') && comparison.fetch('benchmark_runs').zero? &&
          %w[program_source_changes executable_file_changes benchmark_runs].all? { |key| observation.fetch(key).zero? }
        raise 'Incomplete or modified execution cannot yield a scientific array verdict'
      end
      reports = observation.fetch('capture_reports')
      ranks = %w[mpi hybrid].include?(backend) ? %w[rank-0 rank-1 rank-2 rank-3] : ['rank-single']
      unless reports.map { |report| report.fetch('rank') }.sort == ranks &&
          reports.all? { |report| report.fetch('errors').empty? && report.fetch('exit_codes') == [0] }
        raise 'Rank observation coverage differs'
      end
      # All nonstandard streamed layouts are in the shared compatibility pilot.
      # Do not silently accept a new reconstruction without its own verification.
      raise 'New streamed capture requires explicit verification' unless observation.fetch('captured_fragments').empty?
      captured = reports.flat_map do |report|
        report.fetch('captures').map { |object| [report, object] }
      end
      unless captured.size == observation.fetch('objects').size && observation.fetch('objects').all? do |object|
          captured.any? do |report, capture|
            capture.all? { |key, value| object[key] == value } && object.fetch('rank') == report.fetch('rank') &&
              object.fetch('local_path') == File.join(report.fetch('local_directory'), capture.fetch('file'))
          end
        end
        raise 'Array metadata differs from rank captures'
      end
      objects = normalized_objects(record)
      expected = reference.fetch('observation').fetch('objects')
      arrays = comparison.fetch('arrays')
      unless expected.map { |object| object.fetch('name') }.sort == objects.map { |object| object.fetch('name') }.sort &&
          arrays.map { |array| array.fetch('name') }.sort == expected.map { |object| object.fetch('name') }.sort
        raise 'Complete-array coverage differs'
      end
      expected_by_name = expected.to_h { |object| [object.fetch('name'), object] }
      actual_by_name = objects.to_h { |object| [object.fetch('name'), object] }
      arrays.each do |array|
        name = array.fetch('name')
        left, right = expected_by_name.fetch(name), actual_by_name.fetch(name)
        epsilon = tolerance(left, benchmark)
        mismatches = array.fetch('mismatches')
        unless array.fetch('reference_array_sha256') == left.fetch('sha256') &&
            array.fetch('actual_array_sha256') == right.fetch('sha256') &&
            array.fetch('elements') == left.fetch('elements') && array.fetch('elements') == right.fetch('elements') &&
            array.fetch('absolute_tolerance') == epsilon && mismatches.is_a?(Integer) &&
            mismatches.between?(0, array.fetch('elements')) &&
            array.fetch('examples').size == [10, mismatches].min
          raise 'Full-array comparison binding or policy differs'
        end
        if mismatches.zero?
          maximum = array.fetch('maximum_absolute_error')
          raise 'Passing error bound differs' unless maximum.is_a?(Numeric) && maximum.finite? && maximum.between?(0, epsilon)
        end
        next if comparison.fetch('passed')
        values = [[reference.fetch('observation').fetch('id'), left], [id, right]].map do |owner, object|
          data, scalars = witness(root, record.fetch('failure_arrays').fetch(owner).fetch(name))
          unless data.slice('dtype', 'elements', 'bytes', 'sha256', 'fnv1a64') == object.slice('dtype', 'elements', 'bytes', 'sha256', 'fnv1a64')
            raise 'Failure bytes differ from the captured output'
          end
          scalars
        end
        replay = FullArrayOffline.compare_values(*values, epsilon: epsilon)
        raise 'Complete failure comparison does not reproduce' unless replay == array.slice(*replay.keys)
      end
      sparse = validate(reference.fetch('stdout'), logs.fetch('stdout'), benchmark)
      unless sparse == comparison.fetch('sparse_comparison') &&
          comparison.fetch('passed') == (sparse.first && arrays.all? { |array| array.fetch('mismatches').zero? })
        raise 'Combined full-array verdict differs'
      end
      verify_primary_review!(record, reference, root)
      verify_suppressed_review!(record, reference, root)
      verify_root_review!(record, reference, root)
      true
    end

    def verify_execution_review!(record, root)
      review = record.fetch('execution_failure_review')
      comparison = record.fetch('comparison')
      observation = record.fetch('observation')
      unless comparison.fetch('failure_kind') == FullArrayExecutionReviewPolicy::KIND && comparison.fetch('passed') == false &&
          comparison.fetch('arrays').empty? && !record.key?('failure_arrays') &&
          comparison.fetch('sparse_comparison') == [false, FullArrayExecutionReviewPolicy::REASON] &&
          FullArrayOffline.json_digest(review) == record.fetch('execution_failure_review_sha256') &&
          record.fetch('execution_failure_review_sha256') == comparison.fetch('execution_failure_review_sha256') &&
          comparison.fetch('benchmark_runs').zero? &&
          %w[program_source_changes executable_file_changes benchmark_runs].all? { |key| observation.fetch(key).zero? } &&
          %w[extension policy].all? { |name| FullArrayOffline.sha(safe_path(root, review.fetch(name + '_method'))) == review.fetch(name + '_method_sha256') } &&
          FullArrayOffline.sha(File.join(__dir__, 'full_array_execution_review_policy.rb')) == review.fetch('policy_method_sha256') &&
          comparison.fetch('total_check_seconds') == observation.fetch('total_seconds') + review.fetch('unwrapped_diagnostic').fetch('execution').fetch('wall_seconds')
        raise 'Execution review evidence or disposition differs'
      end
      FullArrayExecutionReviewPolicy.verify!(review, comparison.fetch('source'), observation, record.fetch('logs'))
    end

    def verify_suppressed_review!(record, reference, root)
      return unless record.key?('suppressed_output_review')
      review = record.fetch('suppressed_output_review')
      source = record.fetch('comparison').fetch('source')
      observation = record.fetch('observation')
      unless record.fetch('id') == FullArrayOffline::SUPPRESSED_ID && review.fetch('schema_version') == 1 &&
          review.fetch('source_commit') == source.fetch('source_commit') && review.fetch('source_path') == source.fetch('source_path') &&
          review.fetch('source_file') == source.fetch('source_files').fetch('roomsim/roomsim.cpp') &&
          review.fetch('source_file').fetch('git_blob') == '36bc5cd8aade4c247478542768cccb5926e950af' &&
          review.fetch('source_file').fetch('sha256') == '95921633bbb73aba7e173bdad6c0a833f1c5407f925618e82b2051d73beb852a' &&
          review.fetch('stdout_sha256') == observation.fetch('stdout_sha256') &&
          review.fetch('extension_method_sha256') == record.fetch('capture_reconciliation').fetch('extension_method_sha256') &&
          FullArrayOffline.sha(safe_path(root, review.fetch('extension_method'))) == review.fetch('extension_method_sha256') &&
          review.fetch('suppressed_ranks') == %w[rank-1 rank-2 rank-3] && review.fetch('captured_objects') == 4 &&
          observation.fetch('objects').map { |object| object.fetch('rank') }.sort == %w[rank-0 rank-1 rank-2 rank-3] &&
          %w[program_runs benchmark_runs llm_invocations program_source_changes].all? { |key| review.fetch(key).zero? }
        raise 'Suppressed-output review source or method differs'
      end
      verify_root_witnesses!(record, reference, root, review)
    end

    def verify_root_review!(record, reference, root)
      return unless record.key?('root_output_review')
      review = record.fetch('root_output_review')
      profile = review.fetch('profile')
      source = record.fetch('comparison').fetch('source')
      observation = record.fetch('observation')
      ranks = %w[rank-0 rank-1 rank-2 rank-3]
      unless review.fetch('schema_version') == 1 && profile.fetch('schema_version') == 1 &&
          %w[id benchmark backend source_commit source_path].all? { |key| profile.fetch(key) == source.fetch(key) } &&
          %w[mpi hybrid].include?(profile.fetch('backend')) && profile.fetch('printed_rank') == 'rank-0' &&
          profile.fetch('captured_ranks') == ranks &&
          profile.fetch('source_file') == source.fetch('source_files').fetch(profile.fetch('source_file_path')) &&
          !profile.fetch('source_finding').strip.empty? && !profile.fetch('array_name').empty? &&
          profile.fetch('elements').is_a?(Integer) && profile.fetch('elements').positive? &&
          review.fetch('profile_sha256') == FullArrayOffline.json_digest(profile) &&
          review.fetch('stdout_sha256') == observation.fetch('stdout_sha256') &&
          review.fetch('extension_method_sha256') == record.fetch('capture_reconciliation').fetch('extension_method_sha256') &&
          FullArrayOffline.sha(safe_path(root, review.fetch('extension_method'))) == review.fetch('extension_method_sha256') &&
          review.fetch('captured_objects') == 4 &&
          observation.fetch('objects').map { |object| object.fetch('rank') }.sort == ranks &&
          observation.fetch('objects').all? { |object| object.fetch('name') == profile.fetch('array_name') && object.fetch('elements') == profile.fetch('elements') } &&
          %w[program_runs benchmark_runs llm_invocations program_source_changes].all? { |key| review.fetch(key).zero? }
        raise 'Root-output review source, profile or method differs'
      end
      verify_root_witnesses!(record, reference, root, review)
    end

    def verify_root_witnesses!(record, reference, root, review)
      source = record.fetch('comparison').fetch('source')
      observation = record.fetch('observation')
      objects = observation.fetch('objects')
      unless record.fetch('reviewed_replica_arrays').keys.sort == objects.map { |object| object.fetch('sha256') }.uniq.sort
        raise 'Suppressed capture witness coverage differs'
      end
      decoded = objects.to_h do |object|
        data, values = witness(root, record.fetch('reviewed_replica_arrays').fetch(object.fetch('sha256')))
        unless data.slice('dtype', 'elements', 'bytes', 'sha256', 'fnv1a64') == object.slice('dtype', 'elements', 'bytes', 'sha256', 'fnv1a64')
          raise 'Suppressed capture witness differs'
        end
        [object.fetch('sha256'), values]
      end
      expected = reference.fetch('observation').fetch('objects')
      unless expected.size == 1 && record.fetch('review_reference_arrays').keys == expected.map { |object| object.fetch('name') }
        raise 'Suppressed-output reference coverage differs'
      end
      left = expected.first
      right = review.fetch('selected_objects').first
      data, values = witness(root, record.fetch('review_reference_arrays').fetch(left.fetch('name')))
      unless data.slice('dtype', 'elements', 'bytes', 'sha256', 'fnv1a64') == left.slice('dtype', 'elements', 'bytes', 'sha256', 'fnv1a64')
        raise 'Suppressed-output reference bytes differ'
      end
      result = FullArrayOffline.compare_values(values, decoded.fetch(right.fetch('sha256')), epsilon: tolerance(left, source.fetch('benchmark')))
        .merge('name' => left.fetch('name'), 'reference_array_sha256' => left.fetch('sha256'), 'actual_array_sha256' => right.fetch('sha256'))
      raise 'Printed root comparison does not replay' unless record.fetch('comparison').fetch('arrays') == [result]
    end

    def run(directory, quiet: false)
      root = File.realpath(directory)
      receipt = FullArrayOffline.read(File.join(root, 'export.json'))
      raise 'Unsupported full-array export' unless receipt.fetch('schema_version') == 1 && receipt.fetch('kind') == 'full-array-correctness-sweep'
      checked_members(root, receipt)
      shared = receipt.fetch('shared_pilot')
      name = shared.fetch('directory')
      raise 'Unsafe shared pilot location' unless name.match?(/\A[a-zA-Z0-9_-]+\z/)
      pilot = File.join(File.dirname(root), name)
      raise 'Shared pilot receipt changed' unless FullArrayOffline.sha(File.join(pilot, 'export.json')) == shared.fetch('export_sha256')
      pilot_receipt, pilot_records = FullArrayOffline.checked_pilot(pilot)
      FullArrayPilotVerification.run(pilot, quiet: quiet)
      plan = FullArrayOffline.read(File.join(root, 'plan.json'))
      FullArrayOffline.check_pilot_scope!(plan, FullArrayOffline.read(File.join(pilot, 'full-array-pilot-01', 'plan.json')))
      completion = FullArrayOffline.read(File.join(root, 'completion.json'))
      ids = FullArrayOffline.check_completion!(plan, completion, FullArrayOffline.sha(File.join(root, 'plan.json')))
      approval = FullArrayOffline.read(File.join(root, 'authorization.json'))
      unless FullArrayOffline.sha(File.join(root, 'authorization.json')) == plan.fetch('authorization_sha256') &&
          plan.fetch('pilot_plan_sha256') == pilot_receipt.fetch('files_sha256').fetch('full-array-pilot-01/plan.json') &&
          plan.fetch('pilot_completion_sha256') == pilot_receipt.fetch('files_sha256').fetch('full-array-pilot-01/completion.json') &&
          plan.fetch('compatibility_completion_sha256') == pilot_receipt.fetch('files_sha256').fetch('full-array-compatibility-01/completion.json')
        raise 'Full-array authorization or pilot bindings differ'
      end
      FullArrayOffline.check_authorization!(approval, plan.fetch('pilot_plan_sha256'), plan.fetch('pilot_completion_sha256'), ids.size)
      plan.fetch('method_sha256').each do |path, digest|
        raise 'Published runtime method differs' unless pilot_receipt.fetch('files_sha256').fetch(File.join('full-sweep-method', path)) == digest
      end
      groups = plan.fetch('groups').flat_map { |group| group.fetch('full_ids').map { |id| [id, group] } }.to_h
      references = FullArrayOffline.read(File.join(pilot, 'references.json'))
      reference_bindings = FullArrayOffline.read(File.join(pilot, 'build-bindings.json'))
      references.each_value do |reference|
        observation = reference.fetch('observation')
        binding = reference_bindings.fetch(observation.fetch('id'))
        unless FullArrayOffline.json_digest(observation) == reference.fetch('observation_sha256') &&
            Digest::SHA256.hexdigest(reference.fetch('stdout')) == observation.fetch('stdout_sha256') &&
            FullArrayOffline.json_digest(binding) == observation.fetch('binding_sha256') &&
            binding.fetch('binary_sha256') == observation.fetch('binary_sha256')
          raise 'Shared sequential-reference binding differs'
        end
      end
      expected_method = %w[full_array_capture.rb full_array_rank.rb full_array_observer.py full_array_adapters.rb].to_h do |name|
        [name, plan.fetch('method_sha256').fetch(File.join('tools/validation_audit', name))]
      end
      reused = FullArrayOffline.read(File.join(root, 'reused.json'))
      raise 'Reused coverage differs' unless reused.keys.sort == plan.fetch('reused').keys.sort
      accepted = reused.to_h do |id, binding|
        entry = pilot_records.fetch([binding.fetch('phase'), id])
        record = entry.fetch('record')
        original = plan.fetch('reused').fetch(id)
        group = groups.fetch(id)
        unless binding.fetch('line') == entry.fetch('line') && binding.fetch('line_sha256') == entry.fetch('line_sha256') &&
            binding.fetch('phase') == File.dirname(original.fetch('directory')) &&
            binding.fetch('comparison_sha256') == record.fetch('comparison_sha256') &&
            record.fetch('comparison_sha256') == original.fetch('comparison_sha256') &&
            FullArrayOffline.json_digest(record.fetch('observation')) == original.fetch('observation_sha256') &&
            binding.fetch('passed') == record.dig('comparison', 'passed') && record.fetch('id') == id &&
            record.dig('comparison', 'source', 'id') == id && record.dig('observation', 'id') == id &&
            record.dig('comparison', 'source', 'benchmark') == group.fetch('benchmark') &&
            record.dig('comparison', 'source', 'backend') == group.fetch('backend') &&
            record.dig('observation', 'args') == group.fetch('args')
          raise 'Reused pilot comparison differs'
        end
        [id, record]
      end
      locations = reused.to_h do |id, binding|
        [id, { 'path' => File.join(pilot, 'records.jsonl'), 'line' => binding.fetch('line'),
          'line_sha256' => binding.fetch('line_sha256') }]
      end
      shard_names = receipt.fetch('record_shards').map { |shard| shard.fetch('path') }
      unless shard_names == shard_names.uniq && shard_names.sort == receipt.fetch('files_sha256').keys.grep(%r{\Arecords/}).sort
        raise 'Full-array record shards differ'
      end
      receipt.fetch('record_shards').each do |shard|
        path = safe_path(root, shard.fetch('path'))
        unless FullArrayOffline.sha(path) == shard.fetch('sha256') && File.size(path) == shard.fetch('bytes') &&
            File.size(path) <= FullArrayOffline::SHARD_BYTES
          raise 'Full-array shard digest or size differs'
        end
        count = 0
        File.foreach(path) do |line|
          count += 1
          record = JSON.parse(line)
          id = record.fetch('id')
          raise 'Duplicate full-array comparison' if accepted.key?(id)
          group = groups.fetch(id)
          %w[primary_output_review suppressed_output_review root_output_review execution_failure_review].each do |name|
            next unless record.key?(name)
            raise 'Output review plan binding differs' unless record.fetch(name).fetch('plan_sha256') == completion.fetch('plan_sha256')
          end
          verify_record!(record, references.fetch(group.fetch('benchmark')), group, root, expected_method: expected_method)
          accepted[id] = record
          locations[id] = { 'path' => path, 'line' => count, 'line_sha256' => Digest::SHA256.hexdigest(line) }
        end
        raise 'Shard record count differs' unless count == shard.fetch('records')
      end
      failed = accepted.reject { |_id, record| record.dig('comparison', 'passed') }.keys.sort
      unless accepted.keys.sort == ids.sort && receipt.fetch('population') == ids.size &&
          receipt.fetch('new_checks') == plan.fetch('new_checks') && receipt.fetch('reused_checks') == reused.size &&
          failed == receipt.fetch('failed_ids') && failed == completion.fetch('failed_ids') &&
          %w[benchmark_runs llm_invocations program_source_changes].all? { |key| receipt.fetch(key).zero? }
        raise 'Export scope or scientific dispositions differ'
      end
      cases = receipt.fetch('eligibility')
      benchmarks = groups.values.map { |group| group.fetch('benchmark') }.uniq.sort
      raise 'Eligibility case coverage differs' unless cases.keys == benchmarks
      cases.each do |benchmark, summary|
        definition = FullArrayEligibility.definition(benchmark, plan.fetch('groups'))
        pairs = failed.filter_map do |id|
          record = accepted.fetch(id)
          next unless record.dig('comparison', 'source', 'benchmark') == benchmark
          location = locations.fetch(id)
          owner = reused.key?(id) ? pilot : root
          evidence = FullArrayEligibility.location(owner, location.fetch('path'), location.fetch('line'), location.fetch('line_sha256'))
          FullArrayEligibility.rows(record, evidence, definition)
        end
        directory = File.join(root, 'eligibility', benchmark)
        registry = FullArrayEligibility.registry(definition, references.fetch(benchmark), pairs.map(&:first))
        records = pairs.map { |pair| JSON.generate(pair.last) + "\n" }.join
        files = %w[exclusions.json records.jsonl].to_h { |name| [name, FullArrayOffline.sha(File.join(directory, name))] }
        expected = { 'schema_version' => 1, 'case' => definition, 'records' => pairs.size,
          'registry_sha256' => files.fetch('exclusions.json'), 'files_sha256' => files }
        unless FullArrayOffline.read(File.join(directory, 'exclusions.json')) == registry &&
            File.read(File.join(directory, 'records.jsonl')) == records && summary == expected &&
            FullArrayOffline.read(File.join(directory, 'export.json')) == expected
          raise 'Derived eligibility does not match verified full-array evidence'
        end
      end
      execution_failures = accepted.select { |_id, record| record.key?('execution_failure_review') }.keys.sort
      result = { 'verified_files' => receipt.fetch('files_sha256').size, 'verified_records' => accepted.size,
        'reused_pilot_records' => reused.size, 'verified_failure_ids' => failed,
        'full_failure_arrays_reproduced_for' => failed - execution_failures, 'confirmed_execution_failures' => execution_failures,
        'scope' => 'All retained hashes and execution/source bindings verified. Complete failure arrays replay numerical exclusions; separately reviewed execution failures bind source inspection and an unwrapped correctness diagnostic. Successful full-array verdicts remain bound reports without duplicate bulk arrays. No program, compiler or LLM is invoked.' }
      accepted.each { |id, record| yield record, locations.fetch(id) } if block_given?
      puts JSON.pretty_generate(result) unless quiet
      result
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: verify_full_array_full_export.rb FULL_EXPORT' unless ARGV.size == 1
  ValidationAudit::FullArrayFullVerification.run(ARGV.first)
end
