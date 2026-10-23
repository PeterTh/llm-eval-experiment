# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../tools/audit_generation_access"

class GenerationAccessAuditTest < Minitest::Test
  def test_scan_retains_failed_attempts_and_successful_reads_without_automatic_verdict
    Dir.mktmpdir("access-audit-test-", "/tmp") do |root|
      id = "matmul_example_omp_r1"
      directory = File.join(root, id)
      FileUtils.mkdir_p(directory)
      events = [
        { "command" => "cat /home/petert/llm_para_experiments/old/matmul.cpp", "output" => "int main() {}", "exit" => 0 },
        { "command" => "cat /tmp/old-validation/generated/matmul.cpp", "output" => "Permission denied", "exit" => 1 },
        { "command" => "cat /home/llmtest/.copilot/session-state/old/plan.md", "output" => "Prior solution plan", "exit" => 0 },
        { "command" => "cat /home/llmtest/evals/#{File.basename(root)}/#{id}/matmul.cpp", "output" => "own source", "exit" => 0 }
      ].map do |row|
        { "type" => "tool_use", "part" => { "tool" => "bash", "state" => {
          "status" => "completed", "input" => { "command" => row.fetch("command") },
          "output" => row.fetch("output"), "metadata" => { "exit" => row.fetch("exit") } } } }
      end
      File.write(File.join(directory, "output.txt"), events.map { |e| JSON.generate(e) }.join("\n") + "\nnot-json\n")
      report = GenerationAccessAudit.scan(root)
      assert_equal 1, report.fetch("transcripts_scanned")
      row = report.fetch("observations").first
      assert_equal [5], row.fetch("malformed_lines")
      assert_equal [1, 2, 3], row.fetch("candidate_events").map { |e| e.fetch("line") }
      assert_equal [0, 1, 0], row.fetch("candidate_events").map { |e| e.fetch("exit_code") }
      refute row.key?("affected")
      assert_equal Digest::SHA256.hexdigest("int main() {}"), row.fetch("candidate_events").first.fetch("output_sha256")
    end
  end
end
