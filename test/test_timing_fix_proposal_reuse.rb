# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "../tools/timing_audit/bin/timing_fix_proposal_reuse"

class TimingFixProposalReuseTest < Minitest::Test
  def test_reuses_exact_selected_proposal_and_preserves_parent
    with_fixture do |source, destination, id|
      before = Dir[File.join(source, "**/*")].select { |path| File.file?(path) }.to_h { |path| [path, TimingAudit.sha256_file(path)] }
      result = nil
      capture_io { result = TimingFixProposalReuse.run(source: source, destination: destination, model: "gpt-6.1-sol", effort: "high") }
      assert_equal [id], result.fetch("records").map { |row| row.fetch("program_id") }
      assert_equal 0, result.fetch("new_model_requests")
      assert_equal File.binread(File.join(source, "proposals", "#{id}.json")), File.binread(File.join(destination, "proposals", "#{id}.json"))
      before.each { |path, sha| assert_equal sha, TimingAudit.sha256_file(path) }
      assert_equal [id], TimingAudit.load_jsonl(File.join(destination, "summary-full.jsonl")).map { |row| row.fetch("program_id") }
      refute File.exist?(File.join(destination, "proposals", "omitted.json"))
      assert_raises(RuntimeError) { TimingFixProposalReuse.run(source: source, destination: destination, model: "gpt-6.1-sol", effort: "high") }
    end
  end

  def test_rejects_model_or_record_mismatch_without_copying
    %i[model record].each do |fault|
      with_fixture do |source, destination, _id|
        model = fault == :model ? "wrong" : "gpt-6.1-sol"
        if fault == :record
          path = File.join(destination, "inventory.jsonl")
          rows = TimingAudit.load_jsonl(path)
          rows.first["overall_score"] = 9
          File.write(path, TimingAudit.dump_jsonl(rows))
          manifest_path = File.join(destination, "manifest.yaml")
          manifest = YAML.safe_load_file(manifest_path)
          manifest.fetch("artifacts")["inventory_sha256"] = TimingAudit.sha256_file(path)
          File.write(manifest_path, YAML.dump(manifest))
        end
        assert_raises(RuntimeError) { TimingFixProposalReuse.run(source: source, destination: destination, model: model, effort: "high") }
        refute File.exist?(File.join(destination, "proposals"))
      end
    end
  end

  def test_rejects_changed_event_evidence
    with_fixture do |source, destination, id|
      File.open(File.join(source, "logs", id, "attempt-01/events.jsonl"), "a") { |f| f.puts('{"type":"error","message":"changed"}') }
      assert_raises(RuntimeError) { TimingFixProposalReuse.run(source: source, destination: destination, model: "gpt-6.1-sol", effort: "high") }
      refute File.exist?(File.join(destination, "proposals"))
    end
  end

  private

  def with_fixture
    Dir.mktmpdir("proposal-reuse-test-") do |temporary|
      generated = File.join(temporary, "generated")
      id = "example_mpi_r1"
      code = "double elapsed = 0; // Computation time\n"
      path = File.join(generated, "batch", id, "bench/main.cpp")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, code)
      git = ->(*args) { TimingAudit.capture!("git", "-C", generated, *args) }
      git.call("init", "-q"); git.call("config", "user.name", "Test"); git.call("config", "user.email", "test@example.invalid")
      git.call("add", "."); git.call("commit", "-qm", "fixture")
      commit = git.call("rev-parse", "HEAD").strip
      record = { "id" => id, "source_prefix" => "batch/#{id}", "benchmark" => "bench", "model" => "test", "par_type" => "mpi", "overall_score" => nil,
        "metric_label" => "Computation time", "final_decision" => { "final_issue_categories" => ["rank_local_timing"] }, "review_findings" => {} }
      record.merge!(TimingAudit::SourceRepository.new(root: generated, commit: commit).source_record("batch/#{id}"))
      source, destination = %w[source destination].map { |name| File.join(temporary, name) }
      [source, destination].each do |root|
        FileUtils.mkdir_p(root)
        rows = root == source ? [record, record.merge("id" => "omitted")] : [record]
        method = File.expand_path("../tools/timing_audit", __dir__)
        { "prompt-template.txt" => "prompts/timing_fix_prompt.txt", "proposal-schema.json" => "schemas/timing_fix_schema.json", "runner-snapshot.rb" => "lib/timing_fix.rb" }.each { |name, from| FileUtils.cp(File.join(method, from), File.join(root, name)) }
        File.write(File.join(root, "inventory.jsonl"), TimingAudit.dump_jsonl(rows))
        File.write(File.join(root, "trial-ids.txt"), id + "\n")
        names = { "prompt_template_sha256" => "prompt-template.txt", "proposal_schema_sha256" => "proposal-schema.json", "runner_sha256" => "runner-snapshot.rb", "inventory_sha256" => "inventory.jsonl", "trial_ids_sha256" => "trial-ids.txt" }
        artifacts = TimingFixEvidence.bind(root, names.to_h { |key, name| [key, TimingAudit.sha256_file(File.join(root, name))] })
        File.write(File.join(root, "manifest.yaml"), YAML.dump({ "generated_source" => { "root" => generated, "commit" => commit }, "artifacts" => artifacts }))
      end
      proposal = { "program_id" => id, "status" => "proposed", "summary" => "Timing fixture", "expected_timing_semantics" => "Complete duration", "non_timing_changes" => [], "notes" => "",
        "edits" => [{ "path" => "bench/main.cpp", "old_text" => code, "new_text" => code.sub("= 0", "= 1"), "rationale" => "Timing fixture" }] }
      bytes = JSON.pretty_generate(proposal) + "\n"
      prompt = TimingFix::ProposalRunner.new(output_dir: source, scope: "full", jobs: 1).send(:build_prompt, record)
      attempt = File.join(source, "logs", id, "attempt-01")
      FileUtils.mkdir_p([attempt, File.join(source, "proposals")])
      events = TimingAudit.dump_jsonl([{ "type" => "item.completed", "item" => { "type" => "agent_message", "text" => bytes } }, { "type" => "turn.completed" }])
      File.write(File.join(source, "proposals", "#{id}.json"), bytes)
      File.write(File.join(source, "proposals/omitted.json"), JSON.generate({ "program_id" => "omitted", "status" => "cannot_fix" }))
      File.write(File.join(attempt, "events.jsonl"), events)
      File.write(File.join(attempt, "metadata.yaml"), YAML.dump({ "model" => "gpt-6.1-sol", "reasoning_effort" => "high", "exit_code" => 0, "timed_out" => false, "static_only_verified" => true,
        "source_digest" => record.fetch("source_digest"), "result_sha256" => TimingAudit.sha256_bytes(bytes), "events_sha256" => TimingAudit.sha256_bytes(events), "prompt_sha256" => TimingAudit.sha256_bytes(prompt) }))
      yield source, destination, id
    end
  end
end
