# "header" for evaluation scripts

# validation status codes
VS_INVALID = 0
VS_PARALLELIZED = 1
VS_BUILDS = 2
VS_RUNS = 3
VS_INTERNALLY_VALID = 4
VS_FULLY_VALID = 5

class AggregateEvaluation
  attr_reader :benchmark, :model, :par_type, :run
  attr_accessor :input_tokens, :output_tokens, :cached_tokens
  attr_accessor :api_time, :total_time
  attr_accessor :code_additions, :code_deletions
  attr_accessor :non_whitelisted_dependencies
  attr_accessor :validation_status, :validation_err_string
  attr_accessor :benchmark_success, :benchmark_times, :benchmark_median_time
  attr_accessor :overall_score
  attr_accessor :source_batch, :source_path, :total_tokens
  attr_accessor :benchmark_wall_times, :benchmark_config_sha256
  attr_accessor :timing_fixed, :timing_fix_issue_categories
  attr_accessor :original_source_commit, :corrected_source_commit
  attr_accessor :original_source_digest, :corrected_source_digest
  attr_accessor :original_source_url, :corrected_source_url
  attr_accessor :source_correction_amendment_sha256

  def initialize(benchmark, model, par_type, run)
    @benchmark = benchmark
    @model = model
    @par_type = par_type
    @run = run
    @input_tokens = nil
    @output_tokens = nil
    @cached_tokens = nil
    @api_time = nil
    @total_time = nil
    @code_additions = nil
    @code_deletions = nil
    @non_whitelisted_dependencies = nil
    @validation_status = nil
    @validation_err_string = nil
    @benchmark_success = nil
    @benchmark_times = nil
    @benchmark_median_time = nil
    @overall_score = nil
    @source_batch = nil
    @source_path = nil
    @total_tokens = nil
    @benchmark_wall_times = nil
    @benchmark_config_sha256 = nil
    @timing_fixed = false
    @timing_fix_issue_categories = nil
    @original_source_commit = nil
    @corrected_source_commit = nil
    @original_source_digest = nil
    @corrected_source_digest = nil
    @original_source_url = nil
    @corrected_source_url = nil
    @source_correction_amendment_sha256 = nil
  end
end
