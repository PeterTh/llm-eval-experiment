# frozen_string_literal: true
require "digest"
require "open3"

# A mount allowlist, not a model permission or a writable-directory sandbox.
# In particular, read access to previous observations must also be impossible.
# The trusted driver remains outside; all harness/agent processes run inside.
class GenerationFilesystem
  POLICY = "observation-mount-allowlist-v1"
  STATE = "/run/llm-eval/state"
  BINARY = "/run/llm-eval/bin/harness"
  HOME_PATH = "/home/llmtest"
  SYSTEM = %w[/usr /etc /opt /sys].freeze

  def initialize(workspace:, state:, binary:)
    @workspace, @state, @binary = workspace, state, binary
    raise "Unsafe observation workspace" unless workspace.match?(%r{\A/home/llmtest/evals/[^/]+/[^/]+\z})
    raise "Unsafe observation state" unless state.match?(%r{\A/tmp/opencode-observation-[^/]+/private\z})
    [workspace, state, binary].each do |path|
      raise "Noncanonical isolation path: #{path}" unless File.realpath(path) == path
    end
    raise "Missing workspace/state" unless File.directory?(workspace) && File.directory?(state)
    raise "Missing harness executable" unless File.file?(binary) && File.executable?(binary)
    raise "Harness is inside writable observation data" if [workspace, state].any? { |path| binary.start_with?(path + "/") }
    %w[home tmp var-tmp].each do |name|
      path = File.join(state, name)
      raise "Missing or linked isolated directory: #{name}" unless File.directory?(path) && File.realpath(path) == path
    end
    raise "bubblewrap is required; refusing unrestricted fallback" unless File.executable?("/usr/bin/bwrap")
  end

  def prefix
    args = %w[/usr/bin/bwrap --unshare-user --unshare-pid --unshare-ipc
      --disable-userns --assert-userns-disabled --cap-drop ALL --die-with-parent --new-session]
    SYSTEM.each { |path| args.concat(["--ro-bind", path, path]) }
    %w[/bin /sbin /lib /lib64].each do |path|
      next unless File.exist?(path)
      args.concat(File.symlink?(path) ? ["--symlink", File.readlink(path), path] : ["--ro-bind", path, path])
    end
    # Retain native hardware access, but never the host's shared scratch/IPC.
    args.concat(%w[--proc /proc --dev-bind /dev /dev --tmpfs /dev/shm --mqueue /dev/mqueue])
    args.concat(["--bind", File.join(@state, "home"), HOME_PATH,
      "--bind", File.join(@state, "tmp"), "/tmp",
      "--bind", File.join(@state, "var-tmp"), "/var/tmp",
      "--bind", @state, STATE, "--bind", @workspace, @workspace,
      "--ro-bind", @binary, BINARY])
    # /etc/resolv.conf is a symlink on this host. Do not expose the rest of /run.
    resolver = "/run/systemd/resolve"
    args.concat(["--ro-bind", resolver, resolver]) if File.directory?(resolver)
    args.concat(["--chdir", @workspace, "--"])
  end

  def command(*args)
    prefix + [BINARY, *args]
  end

  def self.policy_details(workspace)
    { "policy" => POLICY,
      "system_read_only" => SYSTEM, "private_proc" => true, "private_ipc" => true,
      "private_home" => true, "private_scratch" => %w[/tmp /var/tmp /dev/shm],
      "workspace" => workspace, "state_mount" => STATE, "harness_mount" => BINARY,
      "network" => "unchanged", "hardware_devices" => "unchanged" }
  end

  def self.verify_evidence!(value, workspace:)
    hashes = %w[implementation_sha256 bubblewrap_sha256]
    raise "Invalid filesystem implementation fingerprints" unless hashes.all? { |key| value[key].is_a?(String) && value[key].match?(/\A[0-9a-f]{64}\z/) }
    raise "Filesystem isolation policy differs" unless value.reject { |key, _| (hashes + ["preflight"]).include?(key) } == policy_details(workspace)
    raise "Filesystem isolation preflight failed" unless value["preflight"] == {
      "passed" => true, "operator_home_visible" => false, "other_observations_visible" => false }
    value
  end

  def evidence
    self.class.policy_details(@workspace).merge(
      "implementation_sha256" => Digest::SHA256.file(__FILE__).hexdigest,
      "bubblewrap_sha256" => Digest::SHA256.file("/usr/bin/bwrap").hexdigest)
  end

  def verify!
    # Before any inference, prove that the namespace starts and that neither
    # the operator's home nor another workspace is visible. No permissive retry.
    script = <<~'RUBY'
      require "json"
      workspace = ARGV.fetch(0)
      raise "Operator home visible" if File.exist?("/home/petert")
      raise "Unexpected home" unless Dir.children("/home").sort == ["llmtest"]
      raise "Other observations visible" unless Dir.children(File.dirname(workspace)) == [File.basename(workspace)]
      raise "Current workspace unavailable" unless File.directory?(workspace) && File.writable?(workspace)
      %w[/tmp /var/tmp /dev/shm].each { |path| raise "Scratch unavailable" unless File.writable?(path) }
      raise "Unexpected process view" if Dir["/proc/[0-9]*/root/home/petert"].any? { |path| File.exist?(path) }
      puts JSON.generate({"passed" => true, "operator_home_visible" => false, "other_observations_visible" => false})
    RUBY
    output, error, status = Open3.capture3(*(prefix + ["/usr/bin/ruby", "-e", script, @workspace]))
    raise "Generation filesystem preflight failed: #{error}" unless status.success?
    require "json"
    JSON.parse(output)
  end
end
