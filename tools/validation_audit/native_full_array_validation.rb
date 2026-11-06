# frozen_string_literal: true
require 'tmpdir'
require_relative 'full_array_capture'
require_relative 'full_array_reconcile'

module ValidationAudit
  # Bridge the checked read-only observer into future ordinary validation.
  # Temporary executables/arrays live on local storage. Only bounded reports,
  # source bindings and complete failure witnesses are retained with each result.
  module NativeFullArray
    PHASE = 'native-full-array'
    LOG_PARTS = %w[command stdout stderr exitcode wall_time].freeze
    METHOD_NAMES = %w[native_full_array_validation.rb full_array_capture.rb
      full_array_rank.rb full_array_observer.py full_array_adapters.rb full_array_reconcile.rb].freeze
    # The November 6 addition only enables one previously unobservable binary.
    # Existing complete observations retain their original method receipts, not
    # relabelled receipts or new executions. Unknown historical methods fail shut.
    PRE_STREAMED_OPTIONS_METHOD = {
      'native_full_array_validation.rb' => '794c6bc21c8e4161de1c1af2e86fa3f6e95775cc9ac7eadc15640a08be0076ec',
      'full_array_capture.rb' => '24e32ac199483da9070b984988587ef61feb4bc32a025b09277e84e30cb3d789',
      'full_array_rank.rb' => '234e68fd8dfe8f9a9e1728ccfbbd7d407f2ed88aa721af0f8b836288106af1d1',
      'full_array_observer.py' => '019fa5f8fc3c9fdd8203cb49104506e554815fdbafd8e1d39ee6261a630f75a9',
      'full_array_adapters.rb' => '6554c5e8e2fcd58a942c925fb34d348564f3a8ca1a71ba8efecc398331fde140',
      'full_array_reconcile.rb' => '4b25ebc6be464a26b2e14f9f734b0254998e068c6d9c993aa4f06a721f9b8cf8'
    }.freeze
    module_function

    def definition(benchmark)
      return nil if benchmark == 'floydwarshall' # Complete integer hashes already checked.
      flags = benchmark == 'roomsim' ? %w[-v -o] : %w[-v -r]
      { 'id' => "full-array-#{benchmark}-v1", 'benchmark' => benchmark,
        'args' => flags + LocalEvaluation::ShapeValidationCases::ARGUMENTS.fetch(benchmark),
        'topology' => 'validation', 'timeout' => 30,
        'comparison' => 'complete-arrays-and-existing-summary' }
    end

    def methods
      METHOD_NAMES.to_h { |name| [name, ValidationAudit.sha(File.join(__dir__, name))] }
    end

    def compatible_methods?(recorded, binary_sha256:)
      recorded == methods || (recorded == PRE_STREAMED_OPTIONS_METHOD &&
        binary_sha256 != '82bcac98d064d0427fb90ffd229fc4a03796fa39fd329e38c40e9173366f1873')
    end

    def source_files(root)
      root = File.realpath(root)
      paths = Dir[File.join(root, '**/*')].select { |path| File.file?(path) || File.symlink?(path) }.sort
      raise 'Observer source binding contains symlinks' if paths.any? { |path| File.symlink?(path) }
      raise 'Observer source binding is empty' if paths.empty?
      paths.to_h do |path|
        [path.delete_prefix(root + '/'), { 'sha256' => ValidationAudit.sha(path), 'bytes' => File.size(path) }]
      end
    end

    def normalized(observation, stdout)
      duplicate = observation.fetch('objects').group_by { |object| object.fetch('name') }.values.any? { |group| group.size > 1 }
      return [observation, nil] if observation.fetch('observation_complete') && !duplicate
      selected = FullArrayReconcile.select_identical_replicas(observation, stdout)
      reconciliation = { 'kind' => 'byte-identical-complete-replicas', 'selected_objects' => selected,
        'captured_objects' => observation.fetch('objects').size, 'program_runs' => 0 }
      [observation.merge('objects' => selected, 'errors' => [], 'observation_complete' => true), reconciliation]
    end

    def witness(object, destination)
      bytes = File.binread(object.fetch('local_path'))
      unless bytes.bytesize == object.fetch('bytes') && bytes.bytesize <= 4 * 1024 * 1024 &&
          Digest::SHA256.hexdigest(bytes) == object.fetch('sha256') &&
          (bytes.empty? ? nil : FullArrayCapture.fnv(bytes)) == object.fetch('fnv1a64')
        raise 'Failure witness bytes differ or exceed the retention limit'
      end
      relative = File.join('failure-arrays', object.fetch('sha256') + '.json')
      value = object.slice('dtype', 'elements', 'bytes', 'sha256', 'fnv1a64').merge(
        'encoding' => 'hexadecimal original little-endian scalar bytes', 'values_hex' => bytes.unpack1('H*'))
      path = File.join(destination, relative)
      if File.exist?(path)
        raise 'Conflicting failure witness' unless ValidationAudit.read(path) == value
      else
        ValidationAudit.save(path, value)
      end
      relative
    end

    def checked_files(directory, receipt)
      directory = File.realpath(directory)
      expected = receipt.fetch('files_sha256')
      expected.each do |name, digest|
        raise 'Unsafe native full-array member' unless name.is_a?(String) && !name.start_with?('/') &&
          name.split('/').none? { |part| ['', '.', '..'].include?(part) }
        path = File.join(directory, name)
        unless File.file?(path) && !File.symlink?(path) && File.realpath(path).start_with?(directory + '/') &&
            ValidationAudit.sha(path) == digest
          raise 'Native full-array evidence changed'
        end
      end
      names = Dir[File.join(directory, '**/*')].select { |path| File.file?(path) || File.symlink?(path) }
        .map { |path| path.delete_prefix(directory + '/') }.sort
      raise 'Unpinned native full-array evidence' unless names == (expected.keys + ['receipt.json']).sort
      raise 'Native full-array retention size differs' unless expected.keys.sum { |name| File.size(File.join(directory, name)) } == receipt.fetch('retained_bytes')
      true
    end

    def cache_valid?(output_dir, entry, benchmark:, id:, passed:)
      return false unless entry && entry.fetch('definition') == definition(benchmark) &&
        entry.fetch('evidence_directory') == 'full-array' && entry.fetch('passed') == passed
      directory = File.join(output_dir, 'full-array')
      receipt_path = File.join(directory, 'receipt.json')
      return false unless ValidationAudit.sha(receipt_path) == entry.fetch('receipt_sha256')
      receipt = ValidationAudit.read(receipt_path)
      return false unless receipt.fetch('schema_version') == 1 && receipt.fetch('kind') == PHASE &&
        receipt.fetch('id') == id && receipt.fetch('definition') == definition(benchmark) &&
        receipt.fetch('passed') == passed &&
        %w[benchmark_runs llm_invocations program_source_changes executable_file_changes].all? { |key| receipt.fetch(key).zero? }
      checked_files(directory, receipt)
      actual = ValidationAudit.read(File.join(directory, 'actual.json'))
      bound = actual.fetch('binding')
      compatible_methods?(receipt.fetch('method_sha256'), binary_sha256: bound.fetch('binary_sha256')) &&
        bound.fetch('id') == id && bound.fetch('binary_sha256') == ValidationAudit.sha(File.join(output_dir, LocalEvaluation.executable_name(benchmark))) &&
        bound.fetch('source_files') == source_files(File.join(output_dir, 'source'))
    rescue StandardError
      false
    end

    # Exporters retain only this closed set of JSON reports/witnesses. Builds,
    # raw array files and arbitrary adjacent workspace files are never copied.
    def export_files(output_dir, entry, benchmark:, id:, passed:)
      unless entry.fetch('definition') == definition(benchmark) && entry.fetch('evidence_directory') == 'full-array' &&
          entry.fetch('passed') == passed
        raise 'Native full-array export identity differs'
      end
      directory = File.join(output_dir, 'full-array')
      path = File.join(directory, 'receipt.json')
      raise 'Native full-array export receipt changed' unless ValidationAudit.sha(path) == entry.fetch('receipt_sha256')
      receipt = ValidationAudit.read(path)
      unless receipt.fetch('schema_version') == 1 && receipt.fetch('kind') == PHASE && receipt.fetch('id') == id &&
          receipt.fetch('definition') == definition(benchmark) && receipt.fetch('passed') == passed &&
          %w[benchmark_runs llm_invocations program_source_changes executable_file_changes].all? { |key| receipt.fetch(key).zero? }
        raise 'Native full-array export disposition differs'
      end
      checked_files(directory, receipt)
      names = receipt.fetch('files_sha256').keys
      unless %w[actual.json reference.json comparison.json].all? { |name| names.include?(name) } &&
          names.all? { |name| %w[actual.json reference.json comparison.json].include?(name) || name.match?(%r{\Afailure-arrays/[a-f0-9]{64}\.json\z}) }
        raise 'Unexpected native full-array export member'
      end
      comparison = ValidationAudit.read(File.join(directory, 'comparison.json'))
      unless comparison.fetch('id') == id && comparison.fetch('passed') == passed &&
          comparison.fetch('arrays') == entry.fetch('arrays') && comparison.fetch('sparse_comparison') == entry.fetch('sparse_comparison')
        raise 'Native full-array exported comparison differs'
      end
      (names + ['receipt.json']).sort.map { |name| [File.join(directory, name), name] }
    end

    class Session
      attr_reader :workspace

      def initialize
        @workspace = Dir.mktmpdir('local-full-array-validation-', '/tmp')
        @evidence = File.join(@workspace, 'evidence')
        @references = {}
        @method = NativeFullArray.methods
        @retain_workspace = false
      end

      def close
        return if @closed
        @closed = true
        return if @retain_workspace
        LocalEvaluation::BuildSupport.remove_local_temporary_workspace!(@workspace, required_prefix: 'local-full-array-validation-')
      end

      def binding(id, executable, source_root)
        raise 'Unsafe native observation ID' unless id.match?(/\A[A-Za-z0-9_.-]+\z/)
        source = NativeFullArray.source_files(source_root)
        digest = ValidationAudit.sha(executable)
        local = File.join(@workspace, 'executables', id, File.basename(executable))
        FileUtils.mkdir_p(File.dirname(local))
        raise 'Duplicate native observation ID' if File.exist?(local)
        FileUtils.cp(executable, local, preserve: true)
        raise 'Executable changed during copy' unless ValidationAudit.sha(local) == digest
        value = { 'id' => id, 'source_files' => source, 'executable' => local, 'binary_sha256' => digest }
        ValidationAudit.save(File.join(@evidence, 'bindings', id + '.json'), value)
        value
      end

      def capture(id:, benchmark:, backend:, executable:, source_root:)
        bound = binding(id, executable, source_root)
        observation = FullArrayCapture.capture(workspace: @workspace, evidence: @evidence, id: id,
          benchmark: benchmark, backend: backend, args: NativeFullArray.definition(benchmark).fetch('args'), phase: PHASE)
        unless ValidationAudit.sha(executable) == bound.fetch('binary_sha256') &&
            NativeFullArray.source_files(source_root) == bound.fetch('source_files') && NativeFullArray.methods == @method
          raise 'Source, executable or observer changed during full-array validation'
        end
        directory = File.join(@evidence, PHASE, id)
        logs = LOG_PARTS.to_h { |part| [part, File.read(File.join(directory, 'validation_' + part + '.log'))] }
        normalized, reconciliation = NativeFullArray.normalized(observation, logs.fetch('stdout'))
        raise 'Incomplete observation has no scientific verdict' unless normalized.fetch('observation_complete')
        { 'observation' => observation, 'normalized' => normalized, 'reconciliation' => reconciliation,
          'binding' => bound, 'logs' => logs }
      end

      def reference(benchmark:, executable:, source_root:)
        identity = { 'binary_sha256' => ValidationAudit.sha(executable), 'source_files' => NativeFullArray.source_files(source_root) }
        if @references.key?(benchmark)
          saved = @references.fetch(benchmark)
          raise 'Sequential reference changed within validation' unless saved.fetch('binding').slice(*identity.keys) == identity
          return saved
        end
        @references[benchmark] = capture(id: 'reference_' + benchmark, benchmark: benchmark, backend: 'sequential',
          executable: executable, source_root: source_root)
      end

      def check(id:, benchmark:, backend:, executable:, source_root:, reference_executable:, reference_source_root:, output_dir:)
        definition = NativeFullArray.definition(benchmark)
        raise 'No floating full-array case for this benchmark' unless definition
        destination = File.join(output_dir, 'full-array')
        raise 'Refusing to replace full-array evidence' if File.exist?(destination)
        expected = reference(benchmark: benchmark, executable: reference_executable, source_root: reference_source_root)
        actual = capture(id: id, benchmark: benchmark, backend: backend, executable: executable, source_root: source_root)
        result = FullArrayCapture.compare(expected.fetch('normalized'), actual.fetch('normalized'))
        summary = validate(expected.fetch('logs').fetch('stdout'), actual.fetch('logs').fetch('stdout'), benchmark)
        result['sparse_comparison'] = summary
        result['passed'] &&= summary.first
        %w[reference actual].zip([expected, actual]).each do |name, data|
          ValidationAudit.save(File.join(destination, name + '.json'), data.reject { |key, _| key == 'normalized' })
        end
        unless result.fetch('passed')
          result['failure_arrays'] = [expected, actual].to_h do |data|
            observation = data.fetch('normalized')
            [observation.fetch('id'), observation.fetch('objects').to_h do |object|
              [object.fetch('name'), NativeFullArray.witness(object, destination)]
            end]
          end
        end
        ValidationAudit.save(File.join(destination, 'comparison.json'), result)
        files = Dir[File.join(destination, '**/*')].select { |path| File.file?(path) }.sort
        receipt = { 'schema_version' => 1, 'kind' => PHASE, 'id' => id, 'definition' => definition,
          'passed' => result.fetch('passed'), 'method_sha256' => @method,
          'files_sha256' => files.to_h { |path| [path.delete_prefix(destination + '/'), ValidationAudit.sha(path)] },
          'retained_bytes' => files.sum { |path| File.size(path) }, 'benchmark_runs' => 0, 'llm_invocations' => 0,
          'program_source_changes' => 0, 'executable_file_changes' => 0 }
        path = File.join(destination, 'receipt.json')
        ValidationAudit.save(path, receipt)
        { 'definition' => definition, 'evidence_directory' => 'full-array', 'receipt_sha256' => ValidationAudit.sha(path),
          'passed' => result.fetch('passed'), 'arrays' => result.fetch('arrays'), 'sparse_comparison' => summary }
      rescue StandardError => error
        # Never convert an observer gap or infrastructure failure to a program
        # failure. Leave the local bytes available for a source-bound review.
        @retain_workspace = true
        if output_dir
          # Retain the bounded observation/log evidence in home as well as the
          # local raw arrays. Copy only this point and its sequential reference.
          [id, 'reference_' + benchmark].each do |owner|
            paths = Dir[File.join(@evidence, PHASE, owner, '*')].select { |path| File.file?(path) }
            binding_path = File.join(@evidence, 'bindings', owner + '.json')
            paths << binding_path if File.file?(binding_path)
            paths.each do |path|
              target = File.join(output_dir, 'full-array-incomplete', path.delete_prefix(@evidence + '/'))
              FileUtils.mkdir_p(File.dirname(target))
              FileUtils.cp(path, target)
            end
          end
          LocalEvaluation.atomic_write(File.join(output_dir, 'full_array_infrastructure_error.json'), JSON.pretty_generate(
            'error' => "#{error.class}: #{error.message}", 'local_workspace' => @workspace,
            'method_sha256' => @method, 'scientific_verdict' => nil, 'benchmark_runs' => 0) + "\n")
        end
        raise LocalEvaluation::InfrastructureError, "Full-array observer requires review: #{error.message}; retained local workspace #{@workspace}"
      end
    end
  end
end
