# frozen_string_literal: true
require 'json'
require 'digest'
require_relative '../../validation_helper'

module ValidationAudit
  # Read-only replay primitives. Kept independent of the execution/build stack
  # so artifact verification needs no local machine paths, compilers or GDB.
  # Equivalence tests bind these routines to the frozen sweep implementation.
  module FullArrayOffline
    SYMBOLS = {
      '_Z13print_resultsIdEvRKSt6vectorIT_SaIS1_EEPKc' => ['f64le', 8, 'E*'],
      '_Z13print_resultsIfEvRKSt6vectorIT_SaIS1_EEPKc' => ['f32le', 4, 'e*'],
      '_Z17print_results_intIjEvRKSt6vectorIT_SaIS1_EEPKc' => ['u32le', 4, 'L<*'],
      '_Z17print_results_intIiEvRKSt6vectorIT_SaIS1_EEPKc' => ['i32le', 4, 'l<*']
    }.freeze
    HELPER_SHA = '39dce5caf66268985c8ea44e5c60b619f1cca6e663a0fec4ff9c1dea9cc43e5e'
    HASH_SHA = 'da47685f2f22487193f986eeba67fe414f80d50536a63e03cae0a6935d76a4e9'
    PHASE = 'full-array-full'
    REVIEW_ID = 'roomsim_beam-1.0-oc-medium_hybrid_r5'
    REVIEW_KIND = 'first-printed-complete-result'
    SUPPRESSED_ID = 'roomsim_claude-opus-5.5-cc-medium_mpi_r3'
    SUPPRESSED_KIND = 'root-gather-with-suppressed-partial-captures'
    ROOT_OUTPUT_KIND = 'source-reviewed-root-output'
    SHARD_BYTES = 8 * 1024 * 1024
    module_function

    def read(path) = JSON.parse(File.read(path))
    def sha(path) = Digest::SHA256.file(path).hexdigest

    def fnv(bytes)
      value = 0xcbf29ce484222325
      bytes.each_byte { |byte| value = ((value ^ byte) * 0x100000001b3) & 0xffffffffffffffff }
      format('%016x', value)
    end

    def output_objects(text)
      text.scan(/=== RESULTS ===(.*?)=== END RESULTS ===/m).map do |match|
        lines = match.first.lines.map(&:strip)
        names = lines.grep(/\AName: /)
        counts = lines.grep(/\AElements: /)
        hashes = lines.grep(/\AHash: /)
        raise 'Malformed result object' unless names.size == 1 && counts.size == 1 &&
          counts.first.match?(/\AElements: \d+\z/)
        count = Integer(counts.first.delete_prefix('Elements: '), 10)
        raise 'Malformed result hash' unless count.zero? || hashes.size == 1 && hashes.first.match?(/\AHash: [0-9a-f]{16}\z/)
        { 'name' => names.first.delete_prefix('Name: '), 'elements' => count,
          'fnv1a64' => count.zero? ? nil : hashes.first.delete_prefix('Hash: ') }
      end
    end

    def compare_values(expected, actual, epsilon:)
      raise 'Array count differs' unless expected.size == actual.size
      failed = 0
      max_error = 0.0
      examples = []
      expected.zip(actual).each_with_index do |(reference, value), index|
        raise 'Non-finite sequential reference' unless reference.finite?
        error = value.finite? ? (reference - value).abs : Float::INFINITY
        max_error = [max_error, error].max
        next if error <= epsilon
        failed += 1
        examples << { 'index' => index, 'expected' => reference, 'actual' => value.finite? ? value : value.to_s,
          'absolute_error' => error.finite? ? error : error.to_s } if examples.size < 10
      end
      { 'elements' => expected.size, 'absolute_tolerance' => epsilon, 'mismatches' => failed,
        'maximum_absolute_error' => max_error.finite? ? max_error : max_error.to_s, 'examples' => examples }
    end

    def json_digest(value)
      Digest::SHA256.hexdigest(JSON.pretty_generate(value) + "\n")
    end

    # The comparison already carries the exact source-file manifest. Keep its
    # position in the binding so the original receipt reconstructs byte-for-byte.
    def compact_binding(binding, source)
      raise 'Binding source manifest differs' unless binding.fetch('source_files') == source.fetch('source_files')
      raise 'Reserved compact-binding key' if binding.key?('source_files_from_comparison')
      binding.to_h { |key, value| key == 'source_files' ? ['source_files_from_comparison', true] : [key, value] }
    end

    def expand_binding(binding, source)
      raise 'Missing compact source binding' unless binding.fetch('source_files_from_comparison') == true && !binding.key?('source_files')
      binding.to_h do |key, value|
        key == 'source_files_from_comparison' ? ['source_files', source.fetch('source_files')] : [key, value]
      end
    end

    def check_completion!(plan, completion, plan_digest)
      ids = plan.fetch('groups').flat_map { |group| group.fetch('full_ids') }
      reused = plan.fetch('reused').keys
      failed = completion.fetch('failed_ids')
      unless completion.fetch('status') == 'complete' && completion.fetch('full_scope_accounted_for') == true &&
          completion.fetch('plan_sha256') == plan_digest && ids.size == ids.uniq.size &&
          ids.size == plan.fetch('population') && ids.size == completion.fetch('population') &&
          ids.size == completion.fetch('completed_checks') && reused.size == completion.fetch('reused_checks') &&
          (reused - ids).empty? && plan.fetch('new_checks') == ids.size - reused.size &&
          failed == failed.uniq.sort && (failed - ids).empty? &&
          completion.fetch('passed_checks') == ids.size - failed.size &&
          %w[benchmark_runs llm_invocations].all? { |key| plan.fetch(key).zero? && completion.fetch(key).zero? } &&
          plan.fetch('program_source_changes').zero?
        raise 'Full-array sweep is incomplete or its coverage differs'
      end
      ids
    end

    def checked_pilot(directory)
      receipt = read(File.join(directory, 'export.json'))
      receipt.fetch('files_sha256').each do |name, digest|
        raise 'Unsafe pilot member' if name.start_with?('/') || name.split('/').include?('..')
        path = File.join(directory, name)
        raise 'Published pilot evidence differs' unless File.file?(path) && !File.symlink?(path) && sha(path) == digest
      end
      records = {}
      File.foreach(File.join(directory, 'records.jsonl')).with_index(1) do |line, number|
        record = JSON.parse(line)
        key = [record.fetch('phase'), record.fetch('id')]
        raise 'Duplicate pilot record' if records.key?(key)
        records[key] = { 'record' => record, 'line' => number, 'line_sha256' => Digest::SHA256.hexdigest(line) }
      end
      [receipt, records]
    end

    def check_pilot_scope!(plan, pilot_plan)
      groups = pilot_plan.fetch('groups').map { |group| group.reject { |key, _| key == 'pilot_rows' } }
      unless plan.fetch('population') == pilot_plan.fetch('population') && plan.fetch('groups') == groups
        raise 'Full sweep does not cover the approved pilot population and workloads'
      end
    end

    def check_authorization!(approval, pilot_digest, completion_digest, population)
      raise 'Full-array authorization differs from the approved scope' unless
        approval.fetch('source') == 'user' && approval.fetch('approved') == true &&
        approval.fetch('scope') == 'full-array-correctness-sweep' &&
        approval.fetch('pilot_plan_sha256') == pilot_digest &&
        approval.fetch('pilot_completion_sha256') == completion_digest &&
        approval.fetch('population') == population && approval.fetch('benchmark_runs') == 0 &&
        approval.fetch('llm_invocations') == 0 && !approval.fetch('statement').strip.empty?
    end

  end
end
