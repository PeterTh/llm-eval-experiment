# Helper for experiment.rb, executed as the eval user via su.
#
# Two kinds of work have to run as that user rather than as the harness: reading or rewriting files
# that are mode 0600 and owned by it (Claude Code's credentials and config), and deleting files it
# created in sticky world-writable directories. Doing it here is what lets the harness stay
# unprivileged, like the copilot, pi and codex paths always were.
#
# Usage: ruby eval_user_support.rb <subcommand> [args]
#   claude-reset                              clear everything that could carry context between runs
#   claude-usage                              print the plan usage windows as JSON on stdout
#   sweep <archive> <evals_root> <keep_dir>   archive and delete files left outside the run directory

require "fileutils"
require "json"
require "net/http"
require "open3"

CLAUDE_HOME = File.expand_path("~/.claude")
CLAUDE_CONFIG = File.expand_path("~/.claude.json")
CLAUDE_CREDENTIALS = File.join(CLAUDE_HOME, ".credentials.json")
BASH_HISTORY = File.expand_path("~/.bash_history")
CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"

# Everything under the Claude Code config directory that can carry state between invocations.
# Deliberately keeps .credentials.json (auth), settings.json, policy-limits.json,
# remote-settings.json, plugins/ (read-only marketplace metadata) and cache/.
CLAUDE_STATE_PATHS = %w[projects sessions todos shell-snapshots statsig memory backups
                        CLAUDE.md history.jsonl]

# Shared scratch directories an agent can write to from any working directory. These are the
# channels that survive both the per-run state reset and the move of the results out of reach.
# The override exists so the sweep can be exercised against a fixture; the harness never sets it.
SCRATCH_DIRS = (ENV["EVAL_SCRATCH_DIRS"] || "/tmp /var/tmp /dev/shm").split

def claude_reset!
    CLAUDE_STATE_PATHS.each { |name| FileUtils.rm_rf(File.join(CLAUDE_HOME, name)) }
    # the shell history is a cross-run channel too: one run's commands are readable by the next
    File.write(BASH_HISTORY, "") if File.exist?(BASH_HISTORY)
    return unless File.exist?(CLAUDE_CONFIG)
    # .claude.json records per-directory session state; drop that, keep the account/auth fields
    config = JSON.parse(File.read(CLAUDE_CONFIG))
    config["projects"] = {}
    File.write(CLAUDE_CONFIG, JSON.generate(config))
end

# Claude Code stores the token expiry in epoch milliseconds
def epoch_seconds(value)
    number = value.to_i
    return nil if number <= 0
    number > 100_000_000_000 ? number / 1000 : number
end

def claude_usage
    return warn("no claude credentials at #{CLAUDE_CREDENTIALS}") unless File.exist?(CLAUDE_CREDENTIALS)
    oauth = JSON.parse(File.read(CLAUDE_CREDENTIALS))["claudeAiOauth"]
    return warn("claude credentials have no oauth section") unless oauth.is_a?(Hash) && oauth["accessToken"]
    expires_at = epoch_seconds(oauth["expiresAt"])
    return warn("claude access token has expired") if expires_at && expires_at <= Time.now.to_i
    uri = URI(CLAUDE_USAGE_URL)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 15) do |http|
        http.get(uri.request_uri, {
            "Authorization" => "Bearer #{oauth["accessToken"]}",
            "Content-Type" => "application/json",
            "anthropic-beta" => "oauth-2025-04-20"
        })
    end
    return warn("usage endpoint returned HTTP #{response.code}") unless response.is_a?(Net::HTTPSuccess)
    print response.body
end

# Top-most entries under root that this user owns. Pruning at the first owned directory takes whole
# subtrees in one go, and not descending into directories owned by somebody else keeps the harness
# and the operator's own files out of it entirely.
def owned_entries(root, skip: nil)
    return [] unless File.directory?(root)
    found = []
    stack = [root]
    until stack.empty?
        directory = stack.pop
        begin
            children = Dir.children(directory)
        rescue SystemCallError
            next # another user's private directory, so nothing of ours can be inside it
        end
        children.each do |basename|
            path = File.join(directory, basename)
            next if skip && (path == skip || path.start_with?("#{skip}/"))
            begin
                stat = File.lstat(path) # lstat, so a symlink is taken as a file and never followed
            rescue SystemCallError
                next
            end
            if stat.uid == Process.uid
                found << path
            elsif stat.directory?
                stack << path
            end
        end
    end
    found
end

# Size of the regular files in the swept paths, for the log line. Directories and symlinks are
# skipped so that the figure is the actual payload rather than inode sizes.
def regular_file_bytes(paths)
    paths.sum do |path|
        begin
            stat = File.lstat(path)
        rescue SystemCallError
            next 0
        end
        next stat.size if stat.file?
        next 0 unless stat.directory?
        Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).sum do |entry|
            entry_stat = File.lstat(entry) rescue nil
            entry_stat&.file? ? entry_stat.size : 0
        end
    end
end

def sweep(archive, evals_root, keep_dir)
    paths = SCRATCH_DIRS.flat_map { |dir| owned_entries(dir) }
    # leftovers of an interrupted run: a later agent could otherwise read them
    paths += owned_entries(evals_root, skip: keep_dir)
    return if paths.empty?

    bytes = regular_file_bytes(paths)
    FileUtils.mkdir_p(File.dirname(archive))
    FileUtils.chmod(0777, File.dirname(archive)) # so the harness can move the archive out afterwards

    # gzip -1: the first sweep of a long-running host can be gigabytes, and this is pure scratch
    _out, error, status = Open3.capture3(
        "tar", "--create", "--file", archive, "--use-compress-program", "gzip -1",
        "--directory", "/", "--null", "--files-from", "-", "--ignore-failed-read",
        stdin_data: paths.map { |path| path.delete_prefix("/") }.join("\0")
    )
    # only delete once the archive is safely written
    unless status.success?
        warn "archiving #{paths.size} leftover paths failed, nothing removed: #{error.lines.first}"
        FileUtils.rm_f(archive)
        exit 1
    end
    File.chmod(0644, archive)
    paths.each { |path| FileUtils.rm_rf(path, secure: true) }
    print "#{paths.size} paths, #{bytes} bytes"
end

case ARGV[0]
when "claude-reset" then claude_reset!
when "claude-usage" then claude_usage
when "sweep"
    archive, evals_root, keep_dir = ARGV[1], ARGV[2], ARGV[3]
    abort "sweep needs <archive> <evals_root> <keep_dir>" if [archive, evals_root, keep_dir].any?(&:nil?)
    sweep(archive, evals_root, keep_dir)
else
    warn "usage: ruby #{File.basename(__FILE__)} claude-reset|claude-usage|sweep"
    exit 1
end
