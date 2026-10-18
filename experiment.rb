require "json"
require "time"
require "shellwords"
require "tmpdir"

require_relative "general"
require_relative "lib/experiment_selection"
require_relative "lib/opencode_harness"

# General configuration / information

BENCHMARKS = [
    "black-scholes",
    "cahn-hilliard",
    "cholesky",
    "floydwarshall",
    "matmul",
    "nbody",
    "qtclustering",
    "roomsim",
    "spmv",
    "stencil3d",
    "unstructured"
]


MODELS = {"claude-sonnet-4.5":1,
          "claude-haiku-4.5":0.33,
          "claude-opus-4.6":3,
          "claude-opus-4.5":3,
          "claude-sonnet-4":1,
          "gemini-3-pro-preview":1,
          "gpt-5.2-codex":1,
          "gpt-5.2":1,
          "gpt-5.1-codex-max":1,
          "gpt-5.1-codex":1,
          "gpt-5.1":1,
          "gpt-5":1,
          "gpt-5.1-codex-mini":0.33,
          "gpt-5-mini":0,
          "gpt-4.1":0,
          "qwen-3.6-27B-udq4":0,
          "qwen-3.6-27B-udq4-pi":0,
          "qwen-3.6-27B-udq4-pi-t":0,
          "deepseek-v4-flash":0,
          "qwen3.7-plus":0,
          "gpt-5.6-luna-xhigh":0,
          "gpt-5.6-luna-medium":0,
          "gpt-5.6-luna-low":0,
          "gpt-5.6-terra-xhigh":0,
          "gpt-5.6-terra-medium":0,
          "gpt-5.6-terra-low":0,
          "gpt-5.6-sol-xhigh":0,
          "gpt-5.6-sol-medium":0,
          "gpt-5.6-sol-low":0,
          "gpt-6-sol-medium":0,
          "gpt-6-luna-medium":0,
          "gpt-6-astra-medium":0,
          "gpt-6.1-sol-medium":0,
          "gpt-6.1-sol-xhigh":0,
          "gpt-6.1-sol-oc-medium":0,
          "gpt-6-luna-oc-medium":0,
          "claude-fable-5-cc-medium":0,
          "claude-fable-5.1-cc-medium":0,
          "claude-haiku-5.5-cc-medium":0,
          "claude-opus-5-cc-medium":0,
          "claude-opus-5.5-cc-medium":0,
          "claude-sonnet-5-cc-medium":0,
          "claude-sonnet-5.5-cc-medium":0,
        }

MODEL_MAPPING = {
    "qwen-3.6-27B-udq4" => "unsloth/Qwen3.6-27B-GGUF:UD-Q4_K_XL",
    "qwen-3.6-27B-udq4-pi" => "unsloth/Qwen3.6-27B-GGUF:UD-Q4_K_XL",
    "qwen-3.6-27B-udq4-pi-t" => "unsloth/Qwen3.6-27B-GGUF:UD-Q4_K_XL",
    "gpt-5.6-luna-xhigh" => "gpt-5.6-luna",
    "gpt-5.6-luna-medium" => "gpt-5.6-luna",
    "gpt-5.6-luna-low" => "gpt-5.6-luna",
    "gpt-5.6-terra-xhigh" => "gpt-5.6-terra",
    "gpt-5.6-terra-medium" => "gpt-5.6-terra",
    "gpt-5.6-terra-low" => "gpt-5.6-terra",
    "gpt-5.6-sol-xhigh" => "gpt-5.6-sol",
    "gpt-5.6-sol-medium" => "gpt-5.6-sol",
    "gpt-5.6-sol-low" => "gpt-5.6-sol",
    "gpt-6-sol-medium" => "gpt-6-sol",
    "gpt-6-luna-medium" => "gpt-6-luna",
    "gpt-6-astra-medium" => "gpt-6-astra",
    "gpt-6.1-sol-medium" => "gpt-6.1-sol",
    "gpt-6.1-sol-xhigh" => "gpt-6.1-sol",
    "gpt-6.1-sol-oc-medium" => "openai/gpt-6.1-sol",
    "gpt-6-luna-oc-medium" => "openai/gpt-6-luna",
    "claude-fable-5-cc-medium" => "claude-fable-5",
    "claude-fable-5.1-cc-medium" => "claude-fable-5-1",
    "claude-haiku-5.5-cc-medium" => "claude-haiku-5-5",
    "claude-opus-5-cc-medium" => "claude-opus-5",
    "claude-opus-5.5-cc-medium" => "claude-opus-5-5",
    "claude-sonnet-5-cc-medium" => "claude-sonnet-5",
    "claude-sonnet-5.5-cc-medium" => "claude-sonnet-5-5",
}

REASONING_MAPPING = {
    "gpt-5.6-luna-xhigh" => "xhigh",
    "gpt-5.6-luna-medium" => "medium",
    "gpt-5.6-luna-low" => "low",
    "gpt-5.6-terra-xhigh" => "xhigh",
    "gpt-5.6-terra-medium" => "medium",
    "gpt-5.6-terra-low" => "low",
    "gpt-5.6-sol-xhigh" => "xhigh",
    "gpt-5.6-sol-medium" => "medium",
    "gpt-5.6-sol-low" => "low",
    "gpt-6-sol-medium" => "medium",
    "gpt-6-luna-medium" => "medium",
    "gpt-6-astra-medium" => "medium",
    "gpt-6.1-sol-medium" => "medium",
    "gpt-6.1-sol-xhigh" => "xhigh",
    "gpt-6.1-sol-oc-medium" => "medium",
    "gpt-6-luna-oc-medium" => "medium",
    "claude-fable-5-cc-medium" => "medium",
    "claude-fable-5.1-cc-medium" => "medium",
    "claude-haiku-5.5-cc-medium" => "medium",
    "claude-opus-5-cc-medium" => "medium",
    "claude-opus-5.5-cc-medium" => "medium",
    "claude-sonnet-5-cc-medium" => "medium",
    "claude-sonnet-5.5-cc-medium" => "medium",
}

REASONING_EFFORTS_CLAUDE = %w[low medium high xhigh max]

BASE_COST_PER_REQUEST = 0.04 # base cost in dollars for github copilot requests, to multiply with per-model cost factors

PARAMS = "--allow-all-paths --allow-all-tools --no-ask-user --no-color --autopilot"

PARAMS_CODEX = '--dangerously-bypass-approvals-and-sandbox --disable apps --disable auth_elicitation --disable browser_use --disable browser_use_external --disable browser_use_full_cdp_access --disable computer_use --disable daemon_auto_start --disable in_app_browser --disable in_app_updates --disable image_generation --disable memories --disable mentions_v2 --disable multi_agent --disable multi_agent_v2 --disable plugin_sharing --disable plugins --disable remote_plugin --disable skill_mcp_dependency_install --disable tool_call_mcp_elicitation --disable tool_suggest --disable workspace_dependencies'
CODEX_BINARY = ENV.fetch("LLM_EVAL_CODEX_BINARY", "codex")
OPENCODE_BINARY = ENV.fetch("LLM_EVAL_OPENCODE_BINARY", "/home/llmtest/.local/share/opencode-eval/versions/#{OpenCodeHarness::VERSION}/opencode")
OPENCODE_AUTH_FILE = ENV.fetch("LLM_EVAL_OPENCODE_AUTH_FILE", "/home/llmtest/.local/share/opencode-eval/access/data/opencode/auth.json")
OPENCODE_SUPPORT_SCRIPT = File.expand_path("tools/opencode_observation.rb", __dir__)

# Claude Code flags. Full local access (like the other harnesses), but no web tools, no subagents,
# no scheduling or remote triggers, no MCP servers, no settings/hooks/plugins from disk, and no
# session persistence. Bundled skills stay available, matching codex (which only disables
# skill_mcp_dependency_install). Note that --setting-sources "" must use double quotes: the whole
# command is wrapped in single quotes for su.
#
# Disallowed tools, and the codex --disable flag each one corresponds to:
#   WebSearch, WebFetch                      browser_use*, computer_use, in_app_browser
#   Agent (also called Task), Workflow       multi_agent, multi_agent_v2
#   CronCreate, CronDelete, CronList          (no counterpart; they would outlive the run)
#   ScheduleWakeup, RemoteTrigger             (no counterpart; scheduling and external triggers)
# ListAgents, SendMessage, TaskOutput and TaskStop are left alone: they are inert with no subagents.
CLAUDE_DISALLOWED_TOOLS = %w[WebSearch WebFetch Agent Task Workflow
                             CronCreate CronDelete CronList ScheduleWakeup RemoteTrigger]

PARAMS_CLAUDE = "--print --setting-sources \"\" --strict-mcp-config --no-session-persistence " \
                "--no-chrome --dangerously-skip-permissions " \
                "--disallowed-tools #{CLAUDE_DISALLOWED_TOOLS.join(",")} " \
                "--output-format stream-json --verbose"

# su - resets the environment, so these have to be set inside the command string
ENV_CLAUDE = "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 " \
             "DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 DISABLE_BUG_COMMAND=1 " \
             "HISTFILE=/dev/null"

INSTRUCTION_START = "Parallelize the %%1 benchmark code found in $$2 "

PAR_TYPE_INSTRUCTIONS = {
  PAR_OMP => "with OpenMP for multicore CPU shared memory parallelism.",
  PAR_CUDA => "with CUDA for GPU parallelism.",
  PAR_MPI => "with MPI for distributed memory cluster parallelism.",
  PAR_HYBRID => "with a hybrid approach combining MPI, OpenMP, and CUDA as appropriate for the problem for maximum parallel performance on an accelerator cluster."
}

INSTRUCTION_END = 
"""
The program should be optimized for maximum performance and parallel scalability, while maintaining correctness and equivalent semantics to the original code.
Change the code in the existing files only, and do not change the executable name; do not create new files. Update CMakeLists as needed.
The resulting program should unconditionally use the specified parallelization approach. Use no new external dependencies.
"""

EVAL_USER = "llmtest"
EVAL_ROOT = "/home/llmtest/evals"
BENCH_SOURCE = "../benchmarks"


COMMON_SOURCE = "common"

# Claude harness configuration ################################################################

CLAUDE_HOME = "/home/#{EVAL_USER}/.claude"
CLAUDE_CREDENTIALS = File.join(CLAUDE_HOME, ".credentials.json")
CLAUDE_BINARY = ENV.fetch("LLM_EVAL_CLAUDE_BINARY", "/home/#{EVAL_USER}/.local/bin/claude")
# work that has to run as the eval user: reading its 0600 config, and deleting files it created in
# sticky world-writable directories
EVAL_SUPPORT_SCRIPT = File.expand_path("eval_user_support.rb", __dir__)
# staging inside the eval user's home, because it cannot write into the harness user's home
EVAL_STAGING_DIR = "/home/#{EVAL_USER}/.residue"
# deliberately not one of the llm_para_* experiment data paths
EVAL_RESIDUE_ROOT = File.join(Dir.home, "llm_para_agent_residue")

CLAUDE_USAGE_MAX_UTILIZATION = 90   # percent; session and unrecognized usage windows
CLAUDE_WEEKLY_USAGE_MAX_UTILIZATION = 95 # percent; keep a 5% reserve in weekly windows
CLAUDE_USAGE_RECHECK_SECONDS = 300  # re-poll cadence while waiting for a window to reset
CLAUDE_USAGE_WAIT_MARGIN = 60       # seconds added after a window's reset before re-polling
CLAUDE_MAX_RETRIES = 5              # attempts per configuration before giving up
CLAUDE_API_BACKOFF_SECONDS = 120    # multiplied by the attempt number after a transient API error
# HTTP statuses worth another attempt. Claude Code already retries internally, so reaching one of
# these means the overload or outage outlasted its own backoff.
CLAUDE_TRANSIENT_STATUSES = [408, 429, 500, 502, 503, 504, 529]
CLAUDE_RESULT_TAIL_BYTES = 256 * 1024 # how much of output.txt to scan for the final result record
# usage windows that apply to every model, whichever one is being run
CLAUDE_SHARED_WINDOWS = %w[five_hour seven_day]

# Read command line arguments for testing mode, whether to continue an existing run, and whether to actually run ##############################################

SMOKE = ARGV.include?("--smoke")
TESTING = ARGV.include?("--production") ? false : true
DO_RUN = ARGV.include?("--run")
# syntax is --continue=timestamp, e.g. --continue=20240601-120000
CONTINUE_FROM = ARGV.find { |arg| arg.start_with?("--continue=") }&.split("=")&.last
RUN_IDS_FILE = ARGV.find { |arg| arg.start_with?("--run-ids=") }&.split("=", 2)&.last

if ARGV.include?("--help") || ARGV.include?("-h")
    puts "Usage: ruby experiment.rb [options]"
    puts "Options:"
    puts "  --production           Run the full experiment with all configurations (default is testing mode with limited configurations)"
    puts "  --smoke                Smoke test a harness: one benchmark, one parallelization type, one run per model, shorter timeout"
    puts "  --continue=TIMESTAMP   Continue an existing experiment from the given timestamp (format: YYYYMMDD-HHMMSS)"
    puts "  --run-ids=PATH         Select exact IDs (one per line) without changing the mode or per-run budget"
    puts "  --run                  Actually run the experiments (without this flag, the script will only print the planned experiments and estimated time/cost)"
    exit
end


puts "Running in #{SMOKE ? "smoke test" : (TESTING ? "testing" : "production")} mode, with #{DO_RUN ? "actual runs" : "no runs (dry run)"} and #{CONTINUE_FROM ? "continuing from #{CONTINUE_FROM}" : "starting fresh"}."

# Evaluation configuration ####################################################################################################################################

#HARNESS = :copilot
#HARNESS = :pi
#HARNESS = :codex
HARNESS = ENV.fetch("LLM_EVAL_HARNESS", "claude").to_sym
raise "Unknown harness" unless %i[copilot pi codex claude opencode].include?(HARNESS)

if SMOKE
    # Enough to verify a harness end to end (agent edits the sources, transcript is well formed,
    # state reset and usage preflight behave) without spending a campaign's worth of quota.
    BENCHMARKS_TO_EVAL = ["black-scholes"]
    MODELS_TO_EVAL = ENV.fetch("LLM_EVAL_MODELS", "claude-sonnet-5.5-cc-medium").split(",")
    PAR_TYPES_TO_EVAL = [PAR_OMP]
    NUM_RUNS = 1
elsif TESTING
    BENCHMARKS_TO_EVAL = BENCHMARKS # ["black-scholes", "nbody"]
    MODELS_TO_EVAL = ENV.fetch("LLM_EVAL_MODELS", "claude-sonnet-5.5-cc-medium").split(",")
    PAR_TYPES_TO_EVAL = PARALLELIZATION_TYPES
    NUM_RUNS = 5
else
    BENCHMARKS_TO_EVAL = BENCHMARKS
    #MODELS_TO_EVAL = ["claude-sonnet-4.5", "claude-haiku-4.5", "claude-opus-4.6", "gemini-3-pro-preview", "gpt-5.2-codex", "gpt-5.2", "gpt-5-mini", "gpt-4.1"]
    #MODELS_TO_EVAL = ["gpt-5.6-luna-xhigh", "gpt-5.6-luna-medium", "gpt-5.6-luna-low",
    #                  "gpt-5.6-terra-xhigh", "gpt-5.6-terra-medium", "gpt-5.6-terra-low",
    #                  "gpt-5.6-sol-xhigh", "gpt-5.6-sol-medium", "gpt-5.6-sol-low"]
    MODELS_TO_EVAL = ENV.fetch("LLM_EVAL_MODELS", "claude-sonnet-5.5-cc-medium").split(",")
    PAR_TYPES_TO_EVAL = PARALLELIZATION_TYPES
    NUM_RUNS = 5
end

MAX_TIME_SECONDS = SMOKE ? 30 * 60 : 4 * 60 * 60 # after this time we consider a run to be unsuccessful

# Pre-experiment ##############################################################################################################################################

EXPERIMENT_CONFIGURATIONS = ExperimentSelection.select(
    ExperimentSelection.configurations(benchmarks: BENCHMARKS_TO_EVAL, models: MODELS_TO_EVAL,
                                       backends: PAR_TYPES_TO_EVAL, repetitions: NUM_RUNS),
    path: RUN_IDS_FILE
)
$total_experiments = EXPERIMENT_CONFIGURATIONS.size

puts "Total number of experiments to run: #{$total_experiments}"
total_cost = EXPERIMENT_CONFIGURATIONS.sum { |_, model, _, _| MODELS.fetch(model.to_sym) } * BASE_COST_PER_REQUEST
puts "Estimated total cost of the experiment: #{total_cost.round(2)} USD"

TIMESTAMP = CONTINUE_FROM || Time.now.strftime("%Y%m%d-%H%M%S")
EVAL_DIR = File.join(EVAL_ROOT, "#{TIMESTAMP}")
EVAL_TARGET_DIR = File.join(Dir.home, "llm_para_experiments", "#{TIMESTAMP}")

# check correct configuration of benchmark folder
if BENCHMARKS_TO_EVAL.any? { |b| !File.directory?(File.join(BENCH_SOURCE, b)) }
    raise "One or more benchmark folders not found in #{BENCH_SOURCE}. Check the BENCHMARKS list and the BENCH_SOURCE."
end

# Experiment helpers ##########################################################################################################################################

def prepare_folder(benchmark, model, par_type, run)
    id = run_id_string(benchmark, model, par_type, run)
    # Create a folder for the run
    bench_path = File.join(EVAL_DIR, id)
    FileUtils.mkdir_p(bench_path)
    # Copy sequential code of the benchmark to the folder
    FileUtils.cp_r(File.join(BENCH_SOURCE, benchmark), bench_path)
    FileUtils.cp_r(File.join(BENCH_SOURCE, COMMON_SOURCE), bench_path)
    return bench_path
end

$times = []

$runs_to_do = []

# Generate the instruction for the LLM based on the parallelization type
def build_instruction(benchmark, par_type)
    instruction = INSTRUCTION_START.gsub("%%1", benchmark).gsub("$$2", "./" + benchmark + "/")
    instruction += PAR_TYPE_INSTRUCTIONS[par_type]
    instruction += INSTRUCTION_END
    instruction.gsub("\n", " ") # replace newlines with spaces for better handling in the command line
end

# Claude harness helpers ######################################################################

# Shared by the real runs and by the preview printed at startup, so the two cannot drift. The
# effort is fetched rather than defaulted: it is part of the model id, so a missing REASONING_MAPPING
# entry would silently mislabel the run, and --effort only warns on an unknown value.
def claude_command(command_prefix, actual_model_id, effort, instruction)
    "#{command_prefix} env #{ENV_CLAUDE} \"#{CLAUDE_BINARY}\" #{PARAMS_CLAUDE} " \
    "--model #{actual_model_id} --effort #{effort} " \
    "\"#{instruction}\" > output.txt 2>&1"
end

# Claude Code stores some timestamps in epoch milliseconds and others in epoch seconds
def claude_epoch_seconds(value)
    return nil if value.nil?
    number = value.to_i
    return nil if number <= 0
    number > 100_000_000_000 ? number / 1000 : number
end

# The usage endpoint reports reset times as ISO 8601 strings, the credentials file uses epoch
# milliseconds, and the stream-json result record uses epoch seconds
def claude_parse_time(value)
    return nil if value.nil?
    if value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)
        seconds = claude_epoch_seconds(value.is_a?(Numeric) ? value : value.to_s.to_i)
        return seconds ? Time.at(seconds) : nil
    end
    Time.iso8601(value.to_s)
rescue ArgumentError
    nil
end

# Runs an eval_user_support.rb subcommand as the eval user. Returns its stdout, or nil when it
# failed; anything it writes to stderr is passed through so the reason is visible in the log.
def eval_user_support(subcommand)
    output, status = Open3.capture2("su - #{EVAL_USER} --shell=/bin/bash -c " \
                                   "'ruby #{EVAL_SUPPORT_SCRIPT} #{subcommand}'")
    status.success? ? output : nil
end

# Remove everything that could carry context from one invocation to the next
def reset_claude_state!
    raise "Could not reset the claude state for #{EVAL_USER}" if eval_user_support("claude-reset").nil?
end

# An agent can write outside its working directory, so /tmp, /var/tmp, /dev/shm and the leftovers of
# an interrupted run all outlive both the per-run state reset and the move of the results out of
# reach. Everything the eval user left there is archived, then deleted, before the next run starts.
def archive_agent_residue!(id)
    archive = File.join(EVAL_STAGING_DIR, "#{id}.tar.gz")
    summary = eval_user_support("sweep #{archive} #{EVAL_ROOT} #{EVAL_DIR}")
    raise "Could not sweep the files left behind by #{EVAL_USER}" if summary.nil?
    return if summary.strip.empty? # nothing was left behind
    target = File.join(EVAL_RESIDUE_ROOT, TIMESTAMP)
    FileUtils.mkdir_p(target)
    readme = File.join(EVAL_RESIDUE_ROOT, "README.md")
    unless File.exist?(readme)
        File.write(readme,
                   "Files the eval user left outside its run directory (/tmp, /var/tmp, /dev/shm and\n" \
                   "the leftovers of interrupted runs), archived by experiment.rb before a run starts\n" \
                   "so that no agent invocation can read what an earlier one wrote.\n\n" \
                   "<timestamp>/<run id>.tar.gz holds what was found immediately before that run, so\n" \
                   "its contents are what the *previous* run left behind. Paths inside are relative to /.\n")
    end
    # a retry or a --continue sweeps again under the same run id, so do not overwrite the earlier one
    target_path = File.join(target, "#{id}.tar.gz")
    suffix = 1
    while File.exist?(target_path)
        target_path = File.join(target, "#{id}.#{suffix}.tar.gz")
        suffix += 1
    end
    FileUtils.mv(archive, target_path)
    puts " - Archived leftover files (#{summary.strip}) to #{File.basename(target_path)}"
end

# Queries the plan usage windows that /usage renders. Returns the parsed body, or nil if the check
# could not be performed (expired token, network problem, unexpected response).
def claude_usage_snapshot
    output = eval_user_support("claude-usage")
    return nil if output.nil? || output.strip.empty?
    JSON.parse(output)
rescue StandardError => e
    puts " - Usage check returned unusable output (#{e.class}: #{e.message})"
    nil
end

# The usage windows are top-level entries of the response (five_hour, seven_day, seven_day_opus,
# seven_day_sonnet and several plan-specific ones), each either null when it does not apply to the
# plan or a hash of utilization (percent), resets_at (ISO 8601) and locked_reason. Selecting on the
# shape rather than on a list of names means new window types are covered without a code change,
# and it skips the differently shaped extra_usage, spend and limits entries.
def claude_usage_windows(snapshot)
    return {} unless snapshot.is_a?(Hash)
    snapshot.select do |_, window|
        window.is_a?(Hash) && window.key?("utilization") && window.key?("resets_at")
    end
end

# The model family that the endpoint scopes its weekly limits by ("Fable", "Opus", "Sonnet")
def claude_model_family(actual_model_id)
    actual_model_id.to_s[/\A(?:claude-)?([A-Za-z]+)/, 1]&.downcase
end

# Does a normalized limit entry govern the model we are about to run? Entries carry a scope, which
# is null for the shared session and weekly-all windows and names a model for the per-model weekly
# ones, so that e.g. an exhausted Fable window does not hold up Opus and Sonnet runs. Anything whose
# scope we cannot interpret is treated as applicable, which errs towards waiting.
def claude_limit_applies?(limit, family)
    scope = limit["scope"]
    return true unless scope.is_a?(Hash)
    model = scope["model"]
    return true unless model.is_a?(Hash)
    name = model["display_name"] || model["id"]
    return true if name.nil? || family.nil?
    name.to_s.downcase.include?(family)
end

# Weekly capacity needs a smaller reserve than the short session window. Unknown
# window kinds retain the conservative session threshold; model scope is unchanged.
def claude_usage_max_utilization(window_name: nil, limit: nil)
    weekly = window_name.to_s.match?(/\Aseven_day(?:_|\z)/) ||
             (limit.is_a?(Hash) && (limit["group"] == "weekly" ||
               %w[weekly_all weekly_scoped].include?(limit["kind"])))
    weekly ? CLAUDE_WEEKLY_USAGE_MAX_UTILIZATION : CLAUDE_USAGE_MAX_UTILIZATION
end

# Time to wait until, or nil when nothing applicable to this model is exhausted
def claude_usage_blocked_until(snapshot, family = nil)
    return nil unless snapshot.is_a?(Hash)
    fallback = Time.now + CLAUDE_USAGE_RECHECK_SECONDS
    # five_hour and seven_day are shared across models, so they are read directly rather than
    # through the scoped view: a lock or an exhausted window there holds up every run whatever the
    # model, and checking them here means an incomplete limits array cannot cause an under-block
    resets = CLAUDE_SHARED_WINDOWS.filter_map do |name|
        window = snapshot[name]
        next unless window.is_a?(Hash)
        next unless !window["locked_reason"].nil? ||
                    (!window["utilization"].nil? && window["utilization"].to_f >= claude_usage_max_utilization(window_name: name))
        claude_parse_time(window["resets_at"]) || fallback
    end
    limits = snapshot["limits"]
    if limits.is_a?(Array) && !limits.empty?
        resets += limits.filter_map do |limit|
            next unless limit.is_a?(Hash)
            next unless !limit["percent"].nil? && limit["percent"].to_f >= claude_usage_max_utilization(limit: limit)
            next unless claude_limit_applies?(limit, family)
            claude_parse_time(limit["resets_at"]) || fallback
        end
    else
        # no normalized view available, so fall back to the top-level windows; these carry no model
        # scope, so this over-blocks rather than under-blocks
        resets += claude_usage_windows(snapshot).filter_map do |name, window|
            next unless !window["locked_reason"].nil? ||
                        (!window["utilization"].nil? && window["utilization"].to_f >= claude_usage_max_utilization(window_name: name))
            claude_parse_time(window["resets_at"]) || fallback
        end
    end
    resets.max
end

# Blocks until no usage window is exhausted, then returns the snapshot it last saw. Fails open: if
# the check cannot be performed we proceed, since a run that does hit the limit is detected and
# retried afterwards anyway.
def wait_for_claude_usage!(family)
    loop do
        snapshot = claude_usage_snapshot
        if snapshot.nil?
            puts " - Usage unavailable, proceeding without a usage check"
            return nil
        end
        blocked_until = claude_usage_blocked_until(snapshot, family)
        return snapshot if blocked_until.nil?
        remaining = blocked_until - Time.now + CLAUDE_USAGE_WAIT_MARGIN
        wait = remaining <= 0 ? CLAUDE_USAGE_RECHECK_SECONDS : [remaining, CLAUDE_USAGE_RECHECK_SECONDS].min
        puts " - Usage guard for #{family || "this model"} (weekly >=#{CLAUDE_WEEKLY_USAGE_MAX_UTILIZATION}%, session/other >=#{CLAUDE_USAGE_MAX_UTILIZATION}%), resets at #{blocked_until}, waiting #{wait.round}s"
        sleep(wait)
    end
end

# Why a run should be discarded and attempted again instead of being kept as a data point: the plan
# quota ran out mid-run, or the API was overloaded. Returns nil for a run worth keeping, including
# one the agent genuinely failed and one the timeout killed - those are real results.
#
# Note that subtype is "success" even for an API error, so is_error is the field to trust.
def claude_retry_cause(record)
    return nil unless record.is_a?(Hash)
    return :quota if record["rate_limits"].is_a?(Hash)
    return nil unless record["is_error"] == true
    status = record["api_error_status"]
    return :api_error if status.nil? ? record["terminal_reason"] == "api_error" \
                                     : CLAUDE_TRANSIENT_STATUSES.include?(status)
    nil
end

# Final "result" record of a stream-json transcript, scanning backwards from the end of the file
def claude_result_record(output_path)
    return nil unless File.file?(output_path)
    size = File.size(output_path)
    return nil if size.zero?
    data = File.open(output_path, "rb") do |file|
        file.seek(-[size, CLAUDE_RESULT_TAIL_BYTES].min, IO::SEEK_END)
        file.read
    end
    data.force_encoding(Encoding::UTF_8).scrub.lines.reverse_each do |line|
        line = line.strip
        next unless line.start_with?("{") && line.include?("\"result\"")
        begin
            record = JSON.parse(line)
        rescue JSON::ParserError
            next
        end
        return record if record.is_a?(Hash) && record["type"] == "result"
    end
    nil
rescue StandardError => e
    puts " - Could not read the claude result record (#{e.class}: #{e.message})"
    nil
end

def eval_config(benchmark, model, par_type, run, attempt: 1)
    id = run_id_string(benchmark, model, par_type, run)
    print "Evaluating configuration: #{id}"
    print " (attempt #{attempt})" if attempt > 1

    # if we have a timing file for this run already, skip it (for continuing existing runs)
    bench_path = File.join(EVAL_TARGET_DIR, id)
    if (duration = ExperimentSelection.completed_duration(bench_path))
        puts " - Timing file already exists, skipping run"
        # read and update $times for better estimation of remaining time
        $times << duration
        return
    end

    # do this check afterwards so we can test the continue functionality without actually running the experiments
    if !DO_RUN
        puts " - Skipping actual run (dry run mode)"
        $runs_to_do << id
        return
    end

    # all done before the clock starts, so that archiving and waiting do not inflate the duration
    archive_agent_residue!(id)
    claude_usage = nil
    if HARNESS == :claude
        reset_claude_state!
        # only the windows that govern this model should hold the run up
        claude_usage = wait_for_claude_usage!(claude_model_family(MODEL_MAPPING[model] || model))
    end

    start_time = Time.now

    bench_path = prepare_folder(benchmark, model, par_type, run)
    instruction = build_instruction(benchmark, par_type)
    agent_status = nil
    state_parent = nil
    Dir.chdir(bench_path) do
        # give the eval user access to the folder and its contents
        FileUtils.chmod_R(0777, ".")
        # switch to the eval user and run the copilot command; write output to file for later analysis
        actual_model_id = model
        actual_model_id = MODEL_MAPPING[model] if MODEL_MAPPING.keys.include?(model)
        timeout_command = "timeout --kill-after=30s #{MAX_TIME_SECONDS}s"
        command_prefix = "cd #{bench_path}; #{timeout_command}"
        command = ""
        if HARNESS == :pi
            command = "#{command_prefix} pi -p \"#{instruction}\" > output.txt 2>&1"
        elsif HARNESS == :codex
            reasoning_effort = REASONING_MAPPING[model] || "xhigh"
            command = "#{command_prefix} \"#{CODEX_BINARY}\" --model #{actual_model_id} -c model_reasoning_effort=\"#{reasoning_effort}\" #{PARAMS_CODEX} exec \"#{instruction}\" > output.txt 2>&1"
        elsif HARNESS == :claude
            command = claude_command(command_prefix, actual_model_id, REASONING_MAPPING.fetch(model), instruction)
        elsif HARNESS == :opencode
            # Scratch is outside the generated-source folder and on local disk.
            # It is created after the existing residue sweep, never shared with
            # another observation, and never added to the output repository.
            state_parent = Dir.mktmpdir("opencode-observation-", "/tmp")
            FileUtils.chmod(01777, state_parent)
            spec_path = File.join(state_parent, "spec.json")
            spec = { "id" => id, "binary" => OPENCODE_BINARY, "auth_file" => OPENCODE_AUTH_FILE,
                "state" => File.join(state_parent, "private"), "workspace" => bench_path,
                "model" => actual_model_id, "effort" => REASONING_MAPPING.fetch(model),
                "instruction" => instruction, "timeout_seconds" => MAX_TIME_SECONDS }
            File.write(spec_path, JSON.pretty_generate(spec) + "\n")
            preparation_started = Time.now
            preparation = Shellwords.join(["ruby", OPENCODE_SUPPORT_SCRIPT, "prepare", spec_path])
            raise "OpenCode preparation failed" unless system("su", "-", EVAL_USER, "--shell=/bin/bash", "-c", preparation)
            # Configuration inspection/installation is an infrastructure preflight,
            # not model task time. Server and CLI startup remain in the task clock.
            start_time += Time.now - preparation_started
            command = Shellwords.join(["ruby", OPENCODE_SUPPORT_SCRIPT, "run", spec_path]) +
                " > #{Shellwords.escape(File.join(bench_path, 'output.txt'))} 2>&1"
        else
            command = "#{command_prefix} copilot #{PARAMS} --model #{actual_model_id} -p \"#{instruction}\" > output.txt 2>&1"
        end
        output = system("su", "-", EVAL_USER, "--shell=/bin/bash", "-c", command)
        agent_status = $?
        # write instructions to file for later analysis
        File.write(File.join(bench_path, "instruction.txt"), instruction)
    end

    end_time = Time.now
    opencode_process = nil
    opencode_collection_ok = true
    if HARNESS == :opencode && File.file?(File.join(bench_path, "opencode-process.txt"))
        opencode_process = JSON.parse(File.read(File.join(bench_path, "opencode-process.txt")))
        # Native session export/metadata collection happens after the task clock.
        end_time = Time.iso8601(opencode_process.fetch("generation_finished_at"))
        opencode_collection_ok = agent_status&.exitstatus == opencode_process["exit_status"]
    end
    duration = end_time - start_time
    File.write(File.join(bench_path, "process-status.txt"), JSON.pretty_generate({
        "exit_status" => opencode_process ? opencode_process["exit_status"] : agent_status&.exitstatus,
        "term_signal" => opencode_process ? opencode_process["term_signal"] : agent_status&.termsig,
        "success" => agent_status&.success?, "timeout_seconds" => MAX_TIME_SECONDS
    }) + "\n")

    if HARNESS == :claude
        record = claude_result_record(File.join(bench_path, "output.txt"))
        cause = claude_retry_cause(record)
        if cause
            if cause == :quota
                quota = record["rate_limits"]
                resets_at = claude_parse_time(quota["resets_at"])
                puts " - Hit the #{quota["rate_limit_type"] || "usage"} limit after #{duration.round(2)} seconds" \
                     "#{resets_at ? ", resets at #{resets_at}" : ""}"
                wait = resets_at ? resets_at - Time.now + CLAUDE_USAGE_WAIT_MARGIN : CLAUDE_USAGE_RECHECK_SECONDS
                wait = CLAUDE_USAGE_RECHECK_SECONDS if wait <= 0
            else
                puts " - API error after #{duration.round(2)} seconds " \
                     "(status #{record["api_error_status"] || "unknown"}, #{record["terminal_reason"]}): " \
                     "#{record["result"].to_s.lines.first.to_s.strip}"
                wait = CLAUDE_API_BACKOFF_SECONDS * attempt
            end
            # reap anything the agent left behind before we wait
            system("su - #{EVAL_USER} --shell=/bin/bash -c 'pkill -u #{EVAL_USER} -KILL'")
            # leave no trace: the skip check above keys off timing.txt, so a discarded attempt must
            # not be recorded, otherwise --continue would treat it as a completed run.
            # removed as the eval user, since any directory the agent created is owned by it
            system("su - #{EVAL_USER} --shell=/bin/bash -c 'rm -rf #{bench_path}'")
            FileUtils.rm_rf(bench_path)
            if attempt >= CLAUDE_MAX_RETRIES
                puts " - Giving up on #{id} after #{attempt} attempts (#{cause})"
                return
            end
            puts " - Waiting #{wait.round}s, then retrying"
            sleep(wait)
            return eval_config(benchmark, model, par_type, run, attempt: attempt + 1)
        end
        # a run that is kept but did not succeed is a real result, but should not pass unnoticed
        if record.nil?
            puts " - Warning: no result record in the transcript (killed by the timeout?)"
        elsif record["is_error"] == true
            puts " - Warning: run reported is_error (#{record["terminal_reason"]}), keeping it as a result"
        end
        # written after the run so that the agent never sees it; lets throttling and slow mode be
        # audited against the wall clock duration, which is a headline metric
        windows = claude_usage_windows(claude_usage)
        scoped = claude_usage.is_a?(Hash) && claude_usage["limits"].is_a?(Array) ? claude_usage["limits"] : []
        File.write(File.join(bench_path, "usage.txt"),
                   "Windows before run: #{windows.empty? ? "unavailable" : JSON.generate(windows)}\n" \
                   "Scoped limits before run: #{scoped.empty? ? "unavailable" : JSON.generate(scoped)}\n" \
                   "Result record: #{record ? JSON.generate(record.reject { |key, _| key == "result" }) : "unavailable"}\n")
    end

    # write start time, end time and duration to file for later analysis
    File.write(File.join(bench_path, "timing.txt"), "Start time: #{start_time}\nEnd time: #{end_time}\nDuration: #{duration.round(2)} seconds\n")

    # move everything to the target directory, so that subsequent agent runs cannot access the results
    FileUtils.mkdir_p(EVAL_TARGET_DIR)
    FileUtils.mv(bench_path, EVAL_TARGET_DIR)
    if HARNESS == :opencode && state_parent && !File.exist?(File.join(state_parent, "private"))
        FileUtils.remove_entry(state_parent)
    end

    puts " - Done in #{duration.round(2)} seconds."

    # kill stray processes that might still be running (spawned by the LLM)
    system("su - #{EVAL_USER} --shell=/bin/bash -c 'pkill -u #{EVAL_USER} -KILL'")

    # Preserve the native output and exact parent timing before reporting a
    # post-generation collection/cleanup failure. A repair must not force a new
    # model invocation when the completed observation's evidence is recoverable.
    raise "OpenCode evidence collection failed; native result retained" unless opencode_collection_ok

    $times << duration
    avg_time = $times.sum / $times.size
    remaining_experiments = $total_experiments - $times.size
    est_remaining_time = avg_time * remaining_experiments
    puts "Estimated remaining time: #{(est_remaining_time / 3600).round(2)} hours (#{remaining_experiments} experiments left)"
end

# Experiment ##################################################################################################################################################

# sanity check
if HARNESS == :pi
    puts "Using pi harness for evaluation"
    MODELS_TO_EVAL.each do |model|
        # this is a bit jank, but we identify the harness by an addition to the model name string
        if !MODEL_MAPPING.keys.include?(model)
            puts "Model '#{model}' is not in MODEL_MAPPING"
            exit 1
        end
        if !(model.end_with?("-pi") || model.include?("-pi-"))
            puts "Model '#{model}' does not have '-pi' suffix for pi harness"
            exit 1
        end
    end
elsif HARNESS == :codex
    puts "Using codex harness for evaluation"
elsif HARNESS == :opencode
    puts "Using pinned OpenCode #{OpenCodeHarness::VERSION} with subscription-only access"
    MODELS_TO_EVAL.each do |model|
        raise "OpenCode profile must include -oc-" unless model.include?("-oc-")
        OpenCodeHarness.config(model: MODEL_MAPPING.fetch(model), effort: REASONING_MAPPING.fetch(model))
        puts "  --model #{MODEL_MAPPING.fetch(model)} --variant #{REASONING_MAPPING.fetch(model)} --agent build --auto"
    end
    puts "Per-run wall clock limit: #{MAX_TIME_SECONDS / 60} minutes"
    puts "Results are moved to #{EVAL_TARGET_DIR}"
elsif HARNESS == :claude
    puts "Using claude harness for evaluation"
    MODELS_TO_EVAL.each do |model|
        # same convention as the pi harness: the harness is identified by an addition to the model
        # name string, and for claude the reasoning effort is part of the name as well
        if !MODEL_MAPPING.keys.include?(model)
            puts "Model '#{model}' is not in MODEL_MAPPING"
            exit 1
        end
        if !(model.end_with?("-cc") || model.include?("-cc-"))
            puts "Model '#{model}' does not have '-cc' suffix for claude harness"
            exit 1
        end
        effort = REASONING_MAPPING[model]
        if !REASONING_EFFORTS_CLAUDE.include?(effort)
            puts "Model '#{model}' has no valid REASONING_MAPPING entry (got #{effort.inspect}, expected one of #{REASONING_EFFORTS_CLAUDE.join(", ")})"
            exit 1
        end
    end
    [CLAUDE_BINARY, CLAUDE_CREDENTIALS].each do |path|
        next if File.exist?(path)
        puts "Required file for the claude harness is missing: #{path}"
        exit 1
    end
    # report the usage windows up front, so that a broken token or an unexpected utilization scale
    # surfaces here rather than part way through a multi-day campaign
    snapshot = claude_usage_snapshot
    if snapshot.nil?
        puts "Warning: could not read the claude usage windows, runs will proceed without a preflight check"
    else
        summary = claude_usage_windows(snapshot).map do |name, window|
            "#{name}: #{window["utilization"]}% (resets #{claude_parse_time(window["resets_at"]) || "unknown"})"
        end
        if summary.empty?
            puts "Warning: the claude usage endpoint reported no usage windows, runs will proceed without a preflight check"
        else
            puts "Claude usage windows: #{summary.join(", ")}"
        end
        # the normalized view is what the preflight actually uses, because it carries the model scope
        limits = snapshot["limits"].is_a?(Array) ? snapshot["limits"] : []
        if limits.empty?
            puts "Warning: no scoped usage limits reported, the preflight will fall back to blocking on any window"
        else
            limits.each do |limit|
                next unless limit.is_a?(Hash)
                model_scope = limit.dig("scope", "model")
                scope = model_scope.is_a?(Hash) ? (model_scope["display_name"] || model_scope["id"] || "all models") : "all models"
                puts "  limit #{limit["kind"]} (#{scope}): #{limit["percent"]}% (resets #{claude_parse_time(limit["resets_at"]) || "unknown"})"
            end
        end
        puts "Runs wait at #{CLAUDE_WEEKLY_USAGE_MAX_UTILIZATION}% weekly or #{CLAUDE_USAGE_MAX_UTILIZATION}% session/other usage, but only for the limits that govern the model being run"
        MODELS_TO_EVAL.each do |model|
            family = claude_model_family(MODEL_MAPPING[model] || model)
            governing = limits.select { |limit| limit.is_a?(Hash) && claude_limit_applies?(limit, family) }
                              .map { |limit| limit["kind"] }
            puts "  #{model} (#{family}) waits on: #{governing.empty? ? "nothing reported" : governing.join(", ")}"
        end
    end
    # Claude Code discovers memory files by walking up from the working directory, which the
    # per-run state reset cannot cover
    dir = EVAL_DIR
    while dir != "/"
        dir = File.dirname(dir)
        ["CLAUDE.md", ".claude"].each do |name|
            next if name == ".claude" && dir == "/home/#{EVAL_USER}" # reset per run, see above
            path = File.join(dir, name)
            next unless File.exist?(path)
            puts "Unexpected #{name} above the evaluation directory, would leak context between runs: #{path}"
            exit 1
        end
    end
    if !Dir.glob(File.join(BENCH_SOURCE, "**", "CLAUDE.md"), File::FNM_DOTMATCH).empty?
        puts "Unexpected CLAUDE.md inside #{BENCH_SOURCE}, would leak context between runs"
        exit 1
    end
    # print the invocation that will actually be used, so it can be reviewed before a campaign
    example_benchmark, example_model, example_par_type, example_repetition = EXPERIMENT_CONFIGURATIONS.first
    example_id = run_id_string(example_benchmark, example_model, example_par_type, example_repetition)
    example_prefix = "cd #{File.join(EVAL_DIR, example_id)}; timeout --kill-after=30s #{MAX_TIME_SECONDS}s"
    puts "Command for #{example_id}:"
    puts "  su - #{EVAL_USER} --shell=/bin/bash -c '#{claude_command(
        example_prefix,
        MODEL_MAPPING.fetch(example_model, example_model),
        REASONING_MAPPING.fetch(example_model),
        build_instruction(example_benchmark, example_par_type)
    )}'"
    puts "Per-run wall clock limit: #{MAX_TIME_SECONDS / 60} minutes"
    puts "Results are moved to #{EVAL_TARGET_DIR} (Dir.home is #{Dir.home})"
end

EXPERIMENT_CONFIGURATIONS.each do |benchmark, model, par_type, repetition|
    eval_config(benchmark, model, par_type, repetition)
end

if !DO_RUN
    puts "Dry run complete. The following #{$runs_to_do.size} runs would have been executed:\n"
    puts $runs_to_do.join(", ")
end
