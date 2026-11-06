# frozen_string_literal: true
require_relative 'runner'
require_relative 'full_array_adapters'

module ValidationAudit
  # Observation feasibility only. Capture problems are not scientific failures.
  module FullArrayCapture
    SYMBOLS = {
      '_Z13print_resultsIdEvRKSt6vectorIT_SaIS1_EEPKc' => ['f64le', 8, 'E*'],
      '_Z13print_resultsIfEvRKSt6vectorIT_SaIS1_EEPKc' => ['f32le', 4, 'e*'],
      '_Z17print_results_intIjEvRKSt6vectorIT_SaIS1_EEPKc' => ['u32le', 4, 'L<*'],
      '_Z17print_results_intIiEvRKSt6vectorIT_SaIS1_EEPKc' => ['i32le', 4, 'l<*']
    }.freeze
    HELPER_SHA = '39dce5caf66268985c8ea44e5c60b619f1cca6e663a0fec4ff9c1dea9cc43e5e'
    HASH_SHA = 'da47685f2f22487193f986eeba67fe414f80d50536a63e03cae0a6935d76a4e9'
    module_function

    def retain_method(evidence)
      %w[full_array_capture.rb full_array_rank.rb full_array_observer.py full_array_adapters.rb].to_h do |name|
        bytes = File.binread(File.join(__dir__, name))
        digest = Digest::SHA256.hexdigest(bytes)
        directory = File.join(evidence, 'full-array-methods', digest)
        path = File.join(directory, name)
        if File.exist?(path)
          raise 'Observer method archive changed' unless File.binread(path) == bytes
        else
          FileUtils.mkdir_p(directory)
          File.open(path, File::WRONLY | File::CREAT | File::EXCL) { |file| file.write(bytes) }
        end
        [name, digest]
      end
    end

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

    def capture(workspace:, evidence:, id:, benchmark:, backend:, args:, phase:)
      raise 'Unsafe capture ID/phase' unless [id, phase].all? { |s| s.match?(/\A[A-Za-z0-9_.-]+\z/) }
      workspace = File.realpath(workspace)
      raise 'Capture workspace must be local' unless workspace.start_with?('/tmp/')
      binding_path = File.join(evidence, 'bindings', id + '.json')
      binding = ValidationAudit.read(binding_path)
      binary = binding.fetch('executable')
      raise 'Executable binding changed' unless binary.start_with?(workspace + '/') &&
        ValidationAudit.sha(binary) == binding.fetch('binary_sha256')
      raise 'Unsupported hash helper' unless binding.dig('source_files', 'common/hash.hpp', 'sha256') == HASH_SHA
      symbols, error, status = Open3.capture3('nm', binary)
      raise error unless status.success?
      selected = FullArrayAdapters.entries(binding, symbols.lines.map { |line| line.split.last }.uniq, args: args)
      destination = File.join(evidence, phase, id)
      local = File.join(workspace, phase, id)
      raise 'Refusing to overwrite capture' if File.exist?(destination) || File.exist?(local)
      FileUtils.mkdir_p(local)
      configuration = { 'entries' => selected, 'capture_root' => local }
      config_path = File.join(local, 'observer-config.json')
      ValidationAudit.save(config_path, configuration)
      method_hashes = retain_method(evidence)
      launcher = File.expand_path('full_array_rank.rb', __dir__)
      command_args = [launcher, config_path, binary, *args]
      environment, command = if backend == 'sequential'
        [{ 'CUDA_VISIBLE_DEVICES' => '', 'OMP_NUM_THREADS' => '1' }, [RbConfig.ruby, *command_args]]
      else
        LocalEvaluation::Resources.new.command(par_type: backend, executable: RbConfig.ruby,
          args: command_args, mode: :validation)
      end
      before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      execution = LocalEvaluation::ProcessRunner.new.run(argv: command, env: environment,
        prefix: File.join(destination, 'validation'), chdir: File.dirname(binary),
        timeout: 30, limits: LocalEvaluation::ExecutionLimits::VALIDATION)
      output = File.read(File.join(destination, 'validation_stdout.log'))
      errors = []
      errors << 'Observer-wrapped execution did not succeed' unless execution.success
      errors << 'Program did not report internal validation success' unless output.include?('Validation: PASSED') &&
        !output.include?('Validation: FAILED') && !output.include?('Validation fail')
      records = Dir.glob(File.join(local, 'rank-*', 'capture.json')).sort.map do |path|
        report = ValidationAudit.read(path)
        report.merge('rank' => File.basename(File.dirname(path)), 'local_directory' => File.dirname(path))
      end
      expected_ranks = %w[mpi hybrid].include?(backend) ? 4 : 1
      errors << 'Missing rank capture reports' unless records.size == expected_ranks
      objects = []
      records.each do |report|
        errors.concat(report.fetch('errors'))
        errors << "Abnormal inferior exit #{report.fetch('rank')}" unless report.fetch('exit_codes') == [0]
        report.fetch('captures').each do |object|
          raise 'Unsafe capture filename' unless object.fetch('file').match?(/\Aarray-\d+\.(?:f64le|f32le|u32le|i32le)\z/)
          path = File.join(report.fetch('local_directory'), object.fetch('file'))
          bytes = File.binread(path)
          raise 'Captured bytes differ' unless Digest::SHA256.hexdigest(bytes) == object.fetch('sha256') &&
            bytes.bytesize == object.fetch('bytes')
          objects << object.merge('local_path' => path, 'rank' => report.fetch('rank'),
            'fnv1a64' => object.fetch('elements').zero? ? nil : fnv(bytes))
        end
      end
      fragments = []
      if selected.any? { |entry| entry['assembly'] }
        fragments = objects
        begin
          raise 'Ambiguous streamed adapter' unless selected.size == 1
          objects = [case selected.first.fetch('assembly')
          when 'stencil_fixed_faces_and_rank_slabs'
            raise 'Unexpected streamed topology' unless backend == 'hybrid'
            assemble_stencil_slabs(fragments, local)
          when 'black_scholes_contiguous_rank_blocks'
            raise 'Unexpected streamed topology' unless backend == 'mpi'
            assemble_option_blocks(fragments, local)
          when 'stencil_rank_slabs_with_halos'
            raise 'Unexpected streamed topology' unless backend == 'mpi'
            assemble_stencil_halo_slabs(fragments, local)
          else raise 'Unknown streamed adapter'
          end]
        rescue StandardError => error
          errors << "Streamed observation incomplete: #{error.message}"
          objects = []
        end
      end
      printed = output_objects(output)
      captured = objects.map { |object| object.slice('name', 'elements', 'fnv1a64') }
      errors << 'Captured arrays do not match all printed result objects' unless !printed.empty? &&
        printed.sort_by { |r| r.values.map(&:to_s) } == captured.sort_by { |r| r.values.map(&:to_s) }
      errors << 'Executable changed during observation' unless ValidationAudit.sha(binary) == binding.fetch('binary_sha256')
      report = { 'id' => id, 'benchmark' => benchmark, 'backend' => backend, 'args' => args,
        'binding_sha256' => ValidationAudit.sha(binding_path), 'binary_sha256' => binding.fetch('binary_sha256'),
        'method_sha256' => method_hashes,
        'execution' => execution.to_h, 'capture_reports' => records, 'objects' => objects,
        'captured_fragments' => fragments, 'observer_configuration' => configuration,
        'printed_objects' => printed, 'errors' => errors, 'observation_complete' => errors.empty?,
        'total_seconds' => Process.clock_gettime(Process::CLOCK_MONOTONIC) - before,
        'stdout_sha256' => Digest::SHA256.hexdigest(output), 'checked_at' => Time.now.utc.iso8601,
        'program_source_changes' => 0, 'executable_file_changes' => 0, 'benchmark_runs' => 0,
        'scope' => 'Observation feasibility. Capture errors are infrastructure/coverage findings, not scientific exclusions.' }
      ValidationAudit.save(File.join(destination, 'observation.json'), report)
      puts JSON.generate(report.slice('id', 'observation_complete', 'errors', 'total_seconds').merge('arrays' => objects.size))
      $stdout.flush
      report
    end

    # The binary-pinned printDistributedResults receives a const vector on each
    # rank, consumes rank zero first, then receives each other rank in order.
    # Its partition is n / ranks plus one for the first n % ranks. No values
    # come from the reference; the assembled bytes must match its own output hash.
    def assemble_option_blocks(fragments, local)
      total = 10003
      raise 'Missing or repeated option block' unless fragments.size == 4 &&
        fragments.map { |fragment| fragment.fetch('rank') }.sort == %w[rank-0 rank-1 rank-2 rank-3]
      pieces = fragments.sort_by { |fragment| fragment.fetch('rank') }.each_with_index.map do |fragment, rank|
        count = total / 4 + (rank < total % 4 ? 1 : 0)
        raise 'Unexpected option block dimensions' unless fragment.fetch('dtype') == 'f64le' &&
          fragment.fetch('name') == 'OptionPricesBlock' && fragment.fetch('elements') == count
        bytes = File.binread(fragment.fetch('local_path'))
        raise 'Option block changed' unless bytes.bytesize == count * 8 &&
          Digest::SHA256.hexdigest(bytes) == fragment.fetch('sha256')
        bytes
      end
      bytes = pieces.join
      path = File.join(local, 'assembled-option-prices.f64le')
      File.open(path, File::WRONLY | File::CREAT | File::EXCL) { |file| file.write(bytes) }
      { 'name' => 'OptionPrices', 'dtype' => 'f64le', 'elements' => total,
        'bytes' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes), 'local_path' => path,
        'fnv1a64' => fnv(bytes), 'rank' => 'assembled',
        'assembly' => 'Four observed contiguous option blocks in rank order, exactly as the pinned output routine consumes them.' }
    end

    # The pinned reportResults streams each rank's local planes, excluding the
    # leading/trailing communication halos. The fixed global faces are already
    # in those observed planes: no values are synthesized or read from reference.
    # At its inlined output entry the inspected 21-iteration run selects grid2,
    # whose vector object is at rbp-0xf0 on every rank.
    def assemble_stencil_halo_slabs(fragments, local)
      nx, ny, nz = 65, 61, 67
      plane = nx * ny
      raise 'Missing or repeated halo slab' unless fragments.size == 4 &&
        fragments.map { |fragment| fragment.fetch('rank') }.sort == %w[rank-0 rank-1 rank-2 rank-3]
      pieces = fragments.sort_by { |fragment| fragment.fetch('rank') }.each_with_index.map do |fragment, rank|
        depth = nz / 4 + (rank < nz % 4 ? 1 : 0)
        count = (depth + 2) * plane
        raise 'Unexpected halo slab dimensions' unless fragment.fetch('dtype') == 'f64le' &&
          fragment.fetch('name') == 'GridSlabWithHalos' && fragment.fetch('elements') == count
        bytes = File.binread(fragment.fetch('local_path'))
        raise 'Halo slab changed' unless bytes.bytesize == count * 8 &&
          Digest::SHA256.hexdigest(bytes) == fragment.fetch('sha256')
        bytes.byteslice(plane * 8, depth * plane * 8)
      end
      bytes = pieces.join
      path = File.join(local, 'assembled-grid.f64le')
      File.open(path, File::WRONLY | File::CREAT | File::EXCL) { |file| file.write(bytes) }
      { 'name' => 'Grid', 'dtype' => 'f64le', 'elements' => nx * ny * nz,
        'bytes' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes), 'local_path' => path,
        'fnv1a64' => fnv(bytes), 'rank' => 'assembled',
        'assembly' => 'Four observed rank slabs in rank order, excluding only their two communication halo planes, exactly as the pinned output routine consumes them.' }
    end

    # Exact printed-output construction of the pinned streamed implementation:
    # source blob 042bc14e55b8acd6724fc2a8ec8506ddcfe65cd5, lines 253-310.
    # These fixed faces are emitted by that program, not read from the reference.
    # The reconstructed bytes must still match the program's own full-output hash.
    def assemble_stencil_slabs(fragments, local)
      nx, ny, nz = 65, 61, 67
      plane = nx * ny
      raise 'Missing or repeated rank slab' unless fragments.size == 4 &&
        fragments.map { |f| f.fetch('rank') }.sort == %w[rank-0 rank-1 rank-2 rank-3]
      pieces = fragments.sort_by { |f| f.fetch('rank') }.each_with_index.map do |fragment, rank|
        depth = (nz - 2) / 4 + (rank < (nz - 2) % 4 ? 1 : 0)
        raise 'Unexpected slab dimensions' unless fragment.fetch('dtype') == 'f64le' &&
          fragment.fetch('name') == 'GridSlab' && fragment.fetch('elements') == depth * plane
        bytes = File.binread(fragment.fetch('local_path'))
        raise 'Slab changed' unless Digest::SHA256.hexdigest(bytes) == fragment.fetch('sha256')
        bytes
      end
      bytes = Array.new(plane) { |i| (i % 19).to_f }.pack('E*') + pieces.join +
        Array.new(plane) { |i| (((nz - 1) * plane + i) % 19).to_f }.pack('E*')
      path = File.join(local, 'assembled-grid.f64le')
      File.open(path, File::WRONLY | File::CREAT | File::EXCL) { |file| file.write(bytes) }
      { 'name' => 'Grid', 'dtype' => 'f64le', 'elements' => nx * ny * nz,
        'bytes' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes), 'local_path' => path,
        'fnv1a64' => fnv(bytes), 'rank' => 'assembled',
        'assembly' => 'Four observed interior rank slabs in rank order, with the pinned program output routine fixed faces (global index modulo 19).' }
    end

    def compare(reference, actual)
      raise 'Incomplete observation cannot yield a verdict' unless reference.fetch('observation_complete') && actual.fetch('observation_complete')
      raise 'Different workloads' unless reference.fetch('args') == actual.fetch('args') && reference.fetch('benchmark') == actual.fetch('benchmark')
      expected = reference.fetch('objects')
      observed = actual.fetch('objects')
      raise 'Ambiguous array names' unless expected.map { |x| x.fetch('name') }.uniq.size == expected.size &&
        observed.map { |x| x.fetch('name') }.uniq.size == observed.size
      raise 'Array name/count differs' unless expected.map { |o| o.fetch('name') }.sort == observed.map { |o| o.fetch('name') }.sort
      by_name = observed.to_h { |o| [o.fetch('name'), o] }
      results = expected.map do |left|
        right = by_name.fetch(left.fetch('name'))
        values = [left, right].map do |object|
          bytes = File.binread(object.fetch('local_path'))
          raise 'Capture changed' unless Digest::SHA256.hexdigest(bytes) == object.fetch('sha256')
          format = SYMBOLS.values.find { |entry| entry.first == object.fetch('dtype') }.fetch(2)
          bytes.unpack(format)
        end
        tolerance = if left.fetch('dtype').start_with?('i', 'u')
          0
        elsif reference.fetch('benchmark') == 'roomsim' && left.fetch('name').include?('Distance')
          5.0
        else
          1e-5
        end
        compare_values(*values, epsilon: tolerance).merge('name' => left.fetch('name'),
          'reference_array_sha256' => left.fetch('sha256'), 'actual_array_sha256' => right.fetch('sha256'))
      end
      { 'id' => actual.fetch('id'), 'arrays' => results, 'passed' => results.all? { |r| r.fetch('mismatches').zero? },
        'policy' => 'Absolute numerical tolerance 1e-5; Roomsim Distance arrays retain the existing sample tolerance 5. Integer result arrays compare exactly. Cross-program floating-point hashes are not a verdict.',
        'benchmark_runs' => 0 }
    end
  end
end
