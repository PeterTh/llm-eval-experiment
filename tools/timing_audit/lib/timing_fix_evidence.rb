# frozen_string_literal: true

require_relative "timing_audit"

# Shared evidence checks for new correction campaigns. Historical campaigns retain
# their original verification rules unless they explicitly bind this helper.
module TimingFixEvidence
  module_function

  def bind(output_dir, artifacts)
    snapshot = File.join(output_dir, "static-evidence-snapshot.rb")
    TimingAudit.atomic_write(snapshot, File.binread(__FILE__))
    artifacts.merge("static_evidence_sha256" => TimingAudit.sha256_file(snapshot))
  end

  def verify_artifact!(root, manifest)
    expected = manifest.dig("artifacts", "static_evidence_sha256")
    return false unless expected
    [__FILE__, File.join(root, "static-evidence-snapshot.rb")].each do |path|
      raise "Static correction evidence helper changed" unless TimingAudit.sha256_file(path) == expected
    end
    true
  end

  def next_attempt(root, id)
    Dir[File.join(root, "logs", id, "attempt-*")].map { |path| File.basename(path).delete_prefix("attempt-").to_i }.max.to_i + 1
  end

  def stream_metadata(events_path, stderr_path)
    events = TimingAudit.load_jsonl(events_path)
    {
      "events_sha256" => TimingAudit.sha256_file(events_path),
      "stderr_sha256" => TimingAudit.sha256_file(stderr_path),
      "usage" => events.reverse.find { |event| event["type"] == "turn.completed" }&.fetch("usage", nil),
      "diagnostics" => events.filter_map { |event| event.dig("item", "message") if event.dig("item", "type") == "error" }.uniq,
      "transport_errors" => events.filter_map { |event| event["message"] if event["type"] == "error" }.uniq
    }
  end

  def verify_response!(root, id, response, record)
    manifest = YAML.safe_load_file(File.join(root, "manifest.yaml"), aliases: false)
    return true unless verify_artifact!(root, manifest)
    digest_key = record.key?("corrected_source_digest") ? "corrected_source_digest" : "source_digest"
    expected = TimingAudit.sha256_bytes(JSON.pretty_generate(response) + "\n")
    accepted = Dir[File.join(root, "logs", id, "attempt-*", "metadata.yaml")].any? do |path|
      metadata = YAML.safe_load_file(path, aliases: false)
      next false unless metadata["exit_code"] == 0 && !metadata["timed_out"] && metadata["result_sha256"] == expected
      raise "Correction source digest mismatch for #{id}" unless metadata[digest_key] == record.fetch(digest_key)
      events_path = File.join(File.dirname(path), "events.jsonl")
      raise "Correction events changed for #{id}" unless metadata["events_sha256"] == TimingAudit.sha256_file(events_path)
      TimingAudit.verify_static_events!(events_path)
      message = TimingAudit.load_jsonl(events_path).reverse.find { |event| event["type"] == "item.completed" && event.dig("item", "type") == "agent_message" }
      raise "Correction response differs from its event evidence" unless message && JSON.parse(message.fetch("item").fetch("text")) == response
      true
    end
    raise "No verified source-only correction attempt for #{id}" unless accepted
    true
  end

  def add_context(root, template, context_path)
    return template unless context_path
    context = File.read(context_path)
    TimingAudit.atomic_write(File.join(root, "platform-context.txt"), context)
    # Context is literal prose in a Ruby format template; escape any percent signs.
    template + "\nSTATIC TARGET-PLATFORM EVIDENCE\n\n" + context.gsub("%", "%%")
  end

  def review_schema(path)
    schema = JSON.parse(File.read(path))
    schema.fetch("properties").fetch("evidence").fetch("items").fetch("properties").fetch("lines")["pattern"] = "^[1-9][0-9]*(-[1-9][0-9]*)?$"
    JSON.pretty_generate(schema) + "\n"
  end
end
