# frozen_string_literal: true

module LocalEvaluation
  # Exact definitions piloted by the retrospective shape/topology campaign.
  # Shared by retrospective verification and future external validation.
  module ShapeValidationCases
    ARGUMENTS = {
      'black-scholes' => %w[-n 10003], 'cahn-hilliard' => %w[-x 65 -y 61 -z 67 -i 21],
      'cholesky' => %w[-n 513], 'floydwarshall' => %w[-n 513], 'matmul' => %w[-n 513],
      'nbody' => %w[-n 1031 -s 11], 'qtclustering' => %w[-n 1001 -t 1.3],
      'roomsim' => %w[-n 320 -t 101 -s 7 -r 0.7], 'spmv' => %w[-n 1025 -s 40 -i 67],
      'stencil3d' => %w[-x 65 -y 61 -z 67 -i 21], 'unstructured' => %w[-n 33 -i 513]
    }.transform_values(&:freeze).freeze
    FAST_PATH_ARGUMENTS = {
      'cahn-hilliard' => ['large-fused', %w[-v -r -x 512 -i 3].freeze].freeze,
      'stencil3d' => ['large-streaming', %w[-v -r -x 512 -i 3].freeze].freeze,
      'cholesky' => ['large-tile', %w[-v -r -n 1537].freeze].freeze
    }.freeze
    BACKENDS = %w[cuda hybrid mpi omp].freeze
    module_function

    def primary(benchmark, backend)
      raise ArgumentError, 'Unsupported shape-validation backend' unless BACKENDS.include?(backend)
      args = ARGUMENTS.fetch(benchmark).dup
      revision = 1
      if backend == 'mpi'
        if %w[cahn-hilliard stencil3d].include?(benchmark)
          args = %w[-x 129 -y 131 -z 257 -i 21]
          revision = 2
        elsif benchmark == 'unstructured'
          args = %w[-n 257 -i 513]
        end
      end
      flags = benchmark == 'roomsim' ? %w[-v -o] : %w[-v -r]
      definition = { 'id' => "#{benchmark}-shape-#{backend == 'mpi' ? 'mpi128' : 'topology'}-v#{revision}",
        'benchmark' => benchmark, 'args' => (flags + args).freeze, 'topology' => 'measurement', 'timeout' => 30 }
      definition['comparison'] = 'integer_hash' if benchmark == 'floydwarshall'
      definition.freeze
    end

    def for_backend(benchmark, backend)
      definitions = [primary(benchmark, backend)]
      if backend == 'omp' && FAST_PATH_ARGUMENTS.key?(benchmark)
        label, args = FAST_PATH_ARGUMENTS.fetch(benchmark)
        definitions << { 'id' => "#{benchmark}-#{label}-v1", 'benchmark' => benchmark,
          'args' => args, 'topology' => 'measurement', 'timeout' => 30 }.freeze
      end
      definitions
    end

    def definitions
      ARGUMENTS.keys.product(BACKENDS).flat_map { |benchmark, backend| for_backend(benchmark, backend) }
        .to_h { |definition| [definition.fetch('id'), definition] }.freeze
    end
  end
end
