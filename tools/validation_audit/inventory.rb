# frozen_string_literal: true

require 'csv'
require 'json'
require 'digest'
require 'open3'
require 'fileutils'
require_relative '../../lib/local_evaluation'

module ValidationAudit
  SOURCE = '/home/petert/llm_para_experiments'
  INPUT = '/home/petert/llm_eval/benchmarks'
  INPUT_COMMIT = '2bc11aeac658a87b5cae25d03e0669f65d32922e'
  RELEASE = '/home/petert/llm-eval-local'

  module_function
  def sha(path) = Digest::SHA256.file(path).hexdigest
  def read(path) = JSON.parse(File.read(path))
  def git(repository, *args)
    out, err, status = Open3.capture3('git', '-C', repository, *args)
    raise err unless status.success?
    out
  end
  def save(path, value)
    raise "Refusing to overwrite #{path}" if File.exist?(path)
    FileUtils.mkdir_p(File.dirname(path))
    LocalEvaluation.atomic_write(path, JSON.pretty_generate(value) + "\n")
  end
  def id(row) = "#{row.fetch('benchmark')}_#{row.fetch('model')}_#{row.fetch('par_type')}_r#{row.fetch('run')}"
  def stdout(record) = record['logs'] ? record.fetch('logs').fetch('validation_out_stdout.log') : record.fetch('execution').fetch('stdout')

  class Inventory
    attr_reader :rows, :records, :release_commit, :release_digest, :catalog_digest, :record_locations
    def initialize(benchmarks: nil, root: RELEASE)
      @root = root
      @release_commit = ValidationAudit.git(root, 'rev-parse', 'HEAD').strip
      @release_digest = ValidationAudit.sha(File.join(root, 'release/scored_results.csv'))
      @catalog_digest = ValidationAudit.sha(File.join(root, 'release/catalog.json'))
      @rows = CSV.read(File.join(root, 'release/scored_results.csv'), headers: true).map(&:to_h)
        .select { |r| r.fetch('validation_status') == '5' && (!benchmarks || benchmarks.include?(r.fetch('benchmark'))) }
      wanted = @rows.to_h { |row| [ValidationAudit.id(row), true] }
      @records, @record_locations, @campaigns = {}, {}, {}
      catalog = ValidationAudit.read(File.join(root, 'release/catalog.json'))
      catalog.fetch('campaigns').each do |campaign|
        %w[validation_records corrected_validation_records].each do |field|
          load_records(campaign[field], wanted, campaign) if campaign[field]
        end
      end
      if catalog['correction_campaign']
        load_records("#{catalog.fetch('correction_campaign').fetch('root')}/revalidation/validation/records/*/*.jsonl", wanted)
      end
      catalog.fetch('observation_replacements', []).each do |campaign|
        %w[validation_records corrected_validation_records].each do |field|
          load_records(campaign[field], wanted, campaign) if campaign[field]
        end
      end
      raise 'Missing current validation evidence' unless wanted.keys.sort == @records.keys.sort
      @rows.each do |row|
        key = ValidationAudit.id(row)
        record = @records.fetch(key)
        stages = record['stages'] || record.fetch('metadata').fetch('stages')
        raise "Native validation was not successful: #{key}" unless stages.values.all? { |v| v == true }
        row['id'] = key
        row['backend'] = row.fetch('par_type')
        row['source_commit'] = row['timing_fixed'] == 'true' ? row.fetch('corrected_source_commit') :
          (record['source_commit'] || record.dig('source', 'commit') || @campaigns.fetch(key).fetch('source_commit'))
        raise "Missing source revision: #{key}" unless row.fetch('source_commit').to_s.match?(/\A[0-9a-f]{40}\z/)
        row['validation_record'] = @record_locations.fetch(key)
        row['validation_stdout_sha256'] = Digest::SHA256.hexdigest(ValidationAudit.stdout(record))
      end
    end

    def load_records(pattern, wanted, campaign = nil)
      paths = Dir.glob(File.join(@root, pattern)).sort
      raise "Missing validation records #{pattern}" if paths.empty?
      paths.each do |path|
        File.foreach(path).with_index(1) do |line, number|
          record = JSON.parse(line)
          key = record.fetch('id')
          next unless wanted[key]
          @records[key] = record
          @record_locations[key] = { 'path' => path.delete_prefix(@root + '/'), 'line' => number, 'line_sha256' => Digest::SHA256.hexdigest(line) }
          @campaigns[key] = campaign if campaign
        end
      end
    end
  end

  def source_files(row, repository: SOURCE)
    prefix = row.fetch('source_path')
    raise 'Unsafe source prefix' if prefix.start_with?('/') || prefix.split('/').include?('..')
    paths = [row.fetch('benchmark'), 'common'].map { |name| [prefix, name].reject(&:empty?).join('/') }
    git(repository, 'ls-tree', '-r', '-z', row.fetch('source_commit'), '--', *paths).split("\0").filter_map do |entry|
      head, path = entry.split("\t", 2)
      mode, kind, oid = head.split
      next unless kind == 'blob' && %w[100644 100755].include?(mode)
      relative = prefix.empty? ? path : path.delete_prefix(prefix + '/')
      parts = relative.split('/')
      next if parts[0...-1].any? { |part| LocalEvaluation::BuildSupport::GENERATED_DIRECTORY_RE.match?(part) }
      next if LocalEvaluation::BuildSupport::GENERATED_FILE_NAMES.include?(parts.last) || LocalEvaluation::BuildSupport::GENERATED_FILE_EXTENSIONS.include?(File.extname(relative))
      next if mode == '100755' && File.extname(relative).empty? && parts.last != 'configure'
      [relative, { 'git_blob' => oid, 'mode' => mode }]
    end.to_h
  end

  def bind_source(row, repository: SOURCE)
    files = source_files(row, repository: repository)
    raise "Empty source #{row.fetch('id')}" if files.empty?
    files.each_value do |value|
      bytes = git(repository, 'cat-file', 'blob', value.fetch('git_blob'))
      value['sha256'] = Digest::SHA256.hexdigest(bytes)
      value['bytes'] = bytes.bytesize
    end
    digest = Digest::SHA256.new
    files.keys.sort_by { |path| [path.start_with?(row.fetch('benchmark') + '/') ? 0 : 1, path] }
      .each { |path| digest << path << "\0" << files.fetch(path).fetch('sha256') << "\0" }
    row.slice('id', 'benchmark', 'backend', 'source_path', 'source_commit', 'source_batch', 'timing_fixed', 'validation_record', 'validation_stdout_sha256')
      .merge('source_files' => files, 'staged_source_sha256' => digest.hexdigest)
  end

  def archived_source_digest(record)
    record.dig('source_staging', 'content_sha256') || record.dig('source', 'content_sha256')
  end
end
