# frozen_string_literal: true
require "json"
require "digest"
require "open3"
require "timeout"
require "time"
require "tempfile"

# A snapshot of the pinned native client's authenticated upstream catalog, not
# hand-written model definitions or a copy of another observation's state.
module CodexModelCatalog
  class Invalid < StandardError; end
  MOUNT = "/run/llm-eval/state/model-catalog.json"
  SOURCE = "codex_native_authenticated_model_catalog"
  module_function

  def validate!(catalog, model:, effort:)
    models = catalog.is_a?(Hash) && catalog["models"]
    raise Invalid, "Missing model catalog" unless models.is_a?(Array) && !models.empty?
    slugs = models.map { |entry| entry.is_a?(Hash) && entry["slug"] }
    raise Invalid, "Invalid/duplicate model slugs" unless slugs.all? { |s| s.is_a?(String) && !s.empty? } && slugs.uniq == slugs
    selected = models.find { |entry| entry["slug"] == model }
    raise Invalid, "Requested model absent from catalog: #{model}" unless selected
    supported = selected["supported_reasoning_levels"]
    raise Invalid, "Requested effort absent from catalog: #{effort}" unless supported.is_a?(Array) && supported.any? { |v| v.is_a?(Hash) && v["effort"] == effort }
    raise Invalid, "Missing context limit" unless selected["context_window"].is_a?(Integer) && selected["context_window"] > 0
    instructions = selected["model_messages"] || selected["model_instructions"] || selected["base_instructions"]
    raise Invalid, "Missing native model instructions" if instructions.nil? || instructions.empty?
    selected
  end

  def from_cache(raw, version:, model:, effort:, not_before:)
    cache = JSON.parse(raw)
    raise Invalid, "Catalog client version differs" unless cache["client_version"] == version
    fetched = Time.iso8601(cache.fetch("fetched_at"))
    raise Invalid, "Catalog was not freshly fetched" unless fetched >= not_before - 1 && fetched <= Time.now + 5
    # Discard account identity and cache plumbing, but preserve every model
    # definition and field without overrides. This is the native ModelsResponse.
    catalog = { "models" => cache.fetch("models") }
    selected = validate!(catalog, model: model, effort: effort)
    content = JSON.generate(catalog) + "\n"
    receipt = { "schema_version" => 1, "source" => SOURCE, "client_version" => version,
      "fetched_at" => cache.fetch("fetched_at"), "catalog_sha256" => Digest::SHA256.hexdigest(content),
      "catalog_bytes" => content.bytesize, "selected_model" => model, "selected_effort" => effort,
      "selected_model_sha256" => Digest::SHA256.hexdigest(JSON.generate(selected)),
      "context_window" => selected.fetch("context_window"), "definitions_modified" => false,
      "inferences_launched" => 0 }
    [content, receipt]
  rescue KeyError, JSON::ParserError, ArgumentError => e
    raise Invalid, "Invalid native catalog: #{e.class}"
  end

  def verify!(content, receipt, version:, model:, effort:)
    raise Invalid, "Invalid catalog receipt" unless receipt["schema_version"] == 1 && receipt["source"] == SOURCE && receipt["definitions_modified"] == false && receipt["inferences_launched"] == 0
    raise Invalid, "Catalog client version differs" unless receipt["client_version"] == version
    raise Invalid, "Catalog fingerprint differs" unless Digest::SHA256.hexdigest(content) == receipt["catalog_sha256"] && content.bytesize == receipt["catalog_bytes"]
    selected = validate!(JSON.parse(content), model: model, effort: effort)
    if receipt["selected_model"] == model
      raise Invalid, "Selected model metadata differs" unless Digest::SHA256.hexdigest(JSON.generate(selected)) == receipt["selected_model_sha256"]
    end
    selected
  rescue JSON::ParserError => e
    raise Invalid, "Invalid catalog JSON: #{e.class}"
  end

  # Metadata RPCs only. In particular, never send thread/start or turn/start.
  def list_models(command, timeout_seconds: 25)
    diagnostics = +""
    input, output, errors, process = Open3.popen3(*command, pgroup: true)
    drain = Thread.new { errors.each_line { |line| diagnostics << line if diagnostics.bytesize < 32768 } }
    begin
      input.sync = true
      read_result = lambda do |id|
        loop do
          line = output.gets
          raise Invalid, "Metadata service closed before response" unless line
          message = JSON.parse(line)
          next unless message["id"] == id
          raise Invalid, "Metadata RPC rejected" if message["error"]
          break message.fetch("result")
        end
      end
      entries = Timeout.timeout(timeout_seconds) do
        input.puts(JSON.generate({ id: 0, method: "initialize", params: {
          clientInfo: { name: "llm_eval_catalog_preparation", version: "1.0" } } }))
        read_result.call(0)
        input.puts(JSON.generate({ method: "initialized", params: {} }))
        models, cursor, id = [], nil, 1
        loop do
          params = { "limit" => 100, "includeHidden" => true }
          params["cursor"] = cursor if cursor
          input.puts(JSON.generate({ id: id, method: "model/list", params: params }))
          result = read_result.call(id)
          models.concat(result.fetch("data"))
          cursor = result["nextCursor"]
          break models unless cursor
          id += 1
          raise Invalid, "Unexpected catalog pagination" if id > 10
        end
      end
      { "models" => entries, "diagnostics_sha256" => Digest::SHA256.hexdigest(diagnostics) }
    rescue Timeout::Error, JSON::ParserError, KeyError => e
      raise Invalid, "Metadata-only request failed: #{e.class}"
    ensure
      input.close unless input.closed?
      unless process.join(2)
        Process.kill("TERM", -process.pid) rescue Errno::ESRCH
        unless process.join(2)
          Process.kill("KILL", -process.pid) rescue Errno::ESRCH
          process.join
        end
      end
      output.close unless output.closed?
      drain.join(2)
      errors.close unless errors.closed?
    end
  end

  def require_advertised!(result, model:, effort:)
    selected = result.fetch("models").find { |entry| entry["model"] == model }
    raise Invalid, "Native client did not load requested model" unless selected && selected.fetch("supportedReasoningEfforts").any? { |entry| entry["reasoningEffort"] == effort }
    selected
  end

  def publish(path, content)
    raise Invalid, "Catalog destination already exists" if File.exist?(path) || File.symlink?(path)
    Tempfile.create([".catalog-", ".tmp"], File.dirname(path)) do |file|
      file.write(content)
      file.flush
      file.fsync
      file.chmod(0444)
      File.link(file.path, path)
    end
  end
end
