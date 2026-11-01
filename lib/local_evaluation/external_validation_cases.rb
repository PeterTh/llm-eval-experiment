# frozen_string_literal: true

module LocalEvaluation
  # Additional input cases belong to the external-comparison stage. They do not
  # change the sequential input program or any generated implementation.
  module ExternalValidationCases
    UNSTRUCTURED_BOUNDARY = {
      "id" => "unstructured-boundary-v1", "benchmark" => "unstructured",
      "args" => %w[-v -r -n 32 -i 512].freeze
    }.freeze
    module_function

    def cases_for(benchmark, par_type)
      benchmark == "unstructured" && %w[mpi hybrid].include?(par_type) ? [UNSTRUCTURED_BOUNDARY] : []
    end

    def assess(reference, output, execution)
      return [false, "Supplemental execution failed (exit #{execution.exit_code}, timeout #{execution.timed_out})"] unless execution.success
      unless output.include?("Validation: PASSED") && !output.include?("Validation: FAILED") && !output.include?("Validation fail")
        return [false, "Supplemental internal validation did not pass"]
      end
      validate(reference, output, "unstructured")
    end

    def log_digests(prefix)
      %w[command stdout stderr exitcode wall_time].to_h do |suffix|
        name = "#{File.basename(prefix)}_#{suffix}.log"
        [name, LocalEvaluation.sha256_file("#{prefix}_#{suffix}.log")]
      end
    end

    def run(executable:, definition:, par_type:, prefix:, runner:, resources:, timeout:)
      # The executable may be a retained cache on NFS; all new runtime workspace
      # activity stays on local storage. Only bounded evidence logs go to home.
      workspace = Dir.mktmpdir("local-external-validation-", "/tmp")
      local = File.join(workspace, File.basename(executable))
      FileUtils.cp(executable, local, preserve: true)
      env, argv = if par_type == "sequential"
        [{ "CUDA_VISIBLE_DEVICES" => "", "OMP_NUM_THREADS" => "1" }, [local, *definition.fetch("args")]]
      else
        resources.command(par_type: par_type, executable: local, args: definition.fetch("args"), mode: :validation)
      end
      execution = runner.run(argv: argv, env: env, prefix: prefix, chdir: workspace,
        timeout: timeout, limits: ExecutionLimits::VALIDATION)
      [execution, File.read("#{prefix}_stdout.log")]
    ensure
      BuildSupport.remove_local_temporary_workspace!(workspace, required_prefix: "local-external-validation-") if workspace
    end
  end
end
