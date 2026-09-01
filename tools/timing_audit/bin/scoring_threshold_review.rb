#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "optparse"
require "time"
require "yaml"

class ScoringThresholdReview
  MAXIMUM_CLUSTERS = 4
  MINIMUM_NOISE_FLOOR = 1.05

  def initialize(run_dir:, dry_run: false)
    @run_dir = File.expand_path(run_dir)
    @dry_run = dry_run
  end

  def run
    aggregate_path = path("aggregate_results.csv")
    distribution_path = path("local_scoring_distributions.csv")
    proposed_path = path("local_scoring_thresholds.proposed.csv")
    groups = load_successful_groups(aggregate_path)
    verify_distribution!(distribution_path, groups)
    verify_proposed!(proposed_path, groups)

    cells = groups.sort.to_h do |(benchmark, par_type), entries|
      ["#{benchmark}/#{par_type}", review_cell(entries)]
    end
    thresholds = CSV.generate do |csv|
      csv << %w[bench type top great good reviewed]
      cells.each do |key, cell|
        benchmark, par_type = key.split("/", 2)
        csv << [benchmark, par_type, cell.fetch("top"), cell.fetch("great"), cell.fetch("good"), true]
      end
    end
    review = {
      "schema_version" => 1,
      "generated_at" => Time.now.iso8601,
      "distribution_sha256" => sha256(distribution_path),
      "proposed_thresholds_sha256" => sha256(proposed_path),
      "benchmark_full_results_sha256" => sha256(path("benchmark", "benchmark_full_results.yaml")),
      "aggregate_results_sha256" => sha256(path("aggregate_results.yaml")),
      "pipeline_amendment_sha256" => sha256(latest_pipeline_amendment_path),
      "source_correction_amendment_sha256" => sha256(path("source_correction_amendment.yaml")),
      "thresholds_sha256" => Digest::SHA256.hexdigest(thresholds),
      "method" => {
        "space" => "natural breaks minimize within-cluster squared error in log(median_time)",
        "maximum_clusters" => MAXIMUM_CLUSTERS,
        "eligible_boundary" => "adjacent median-time ratio must meet the cell noise floor",
        "noise_floor" => "max(1.05, nearest-rank cell p90 of repetition-4 / repetition-2 across each successful record's five sorted timings)",
        "threshold_location" => "maximum observed median in the faster cluster",
        "collapsed_tiers" => "3 clusters use top/great/baseline; 2 use top/baseline; 1 puts all non-fastest results in top"
      },
      "reviewed" => true,
      "cells" => cells
    }

    if @dry_run
      puts "Threshold review dry run: #{cells.size} cells, #{groups.values.sum(&:size)} successful benchmark records"
      return { "thresholds" => thresholds, "review" => review }
    end

    atomic_write(path("local_scoring_thresholds.csv"), thresholds)
    atomic_write(path("local_scoring_threshold_review.yaml"), YAML.dump(review))
    puts "Wrote reviewed thresholds for #{cells.size} cells to #{@run_dir}"
    { "thresholds" => thresholds, "review" => review }
  end

  private

  def load_successful_groups(aggregate_path)
    rows = CSV.read(aggregate_path, headers: true)
    groups = Hash.new { |hash, key| hash[key] = [] }
    rows.each do |row|
      next unless row.fetch("benchmark_success") == "true"

      times = row.fetch("benchmark_times").split(";").map { |value| Float(value) }
      raise "expected five benchmark repetitions for #{row.fetch('benchmark')}/#{row.fetch('model')}" unless times.size == 5
      median = Float(row.fetch("benchmark_median_time"))
      raise "invalid benchmark median" unless median.positive? && median.finite?
      id = "#{row.fetch('benchmark')}_#{row.fetch('model')}_#{row.fetch('par_type')}_r#{row.fetch('run')}"
      groups[[row.fetch("benchmark"), row.fetch("par_type")]] << {
        "id" => id,
        "median_time" => median,
        "times" => times
      }
    end
    groups.each_value { |entries| entries.sort_by! { |entry| [entry.fetch("median_time"), entry.fetch("id")] } }
    groups
  end

  def verify_distribution!(distribution_path, groups)
    rows = CSV.read(distribution_path, headers: true)
    actual = rows.group_by { |row| [row.fetch("benchmark"), row.fetch("par_type")] }
    raise "distribution cell set does not match aggregate" unless actual.keys.sort == groups.keys.sort

    groups.each do |key, entries|
      distribution_entries = actual.fetch(key)
      raise "distribution count mismatch for #{key.join('/')}" unless distribution_entries.size == entries.size
      entries.zip(distribution_entries).each_with_index do |(entry, row), index|
        raise "distribution rank mismatch for #{key.join('/')}" unless Integer(row.fetch("rank"), 10) == index + 1
        raise "distribution ID mismatch for #{key.join('/')}" unless row.fetch("id") == entry.fetch("id")
        raise "distribution time mismatch for #{entry.fetch('id')}" unless Float(row.fetch("median_time")) == entry.fetch("median_time")
      end
    end
  end

  def verify_proposed!(proposed_path, groups)
    rows = CSV.read(proposed_path, headers: true)
    raise "proposed threshold cell count mismatch" unless rows.size == groups.size
    rows.each do |row|
      key = [row.fetch("bench"), row.fetch("type")]
      entries = groups.fetch(key)
      raise "proposed threshold is already marked reviewed: #{key.join('/')}" unless row.fetch("reviewed") == "false"
      raise "proposed successful count mismatch: #{key.join('/')}" unless Integer(row.fetch("successful_results"), 10) == entries.size
      raise "proposed fastest time mismatch: #{key.join('/')}" unless Float(row.fetch("fastest")) == entries.first.fetch("median_time")
    end
  end

  def review_cell(entries)
    times = entries.map { |entry| entry.fetch("median_time") }
    repeat_ratios = entries.map do |entry|
      repetitions = entry.fetch("times").sort
      repetitions.fetch(3) / repetitions.fetch(1)
    end.sort
    p90 = repeat_ratios.fetch((0.9 * repeat_ratios.size).ceil - 1)
    noise_floor = [MINIMUM_NOISE_FLOOR, p90].max
    eligible = (1...times.size).select { |index| times.fetch(index) / times.fetch(index - 1) >= noise_floor }
    cluster_count = [MAXIMUM_CLUSTERS, eligible.size + 1].min
    segments = optimal_segments(times, eligible, cluster_count)
    cluster_maxima = segments.map { |_start_index, end_index| times.fetch(end_index - 1) }
    tier_indices = case cluster_count
                   when 4 then [0, 1, 2]
                   when 3 then [0, 1, 1]
                   else [0, 0, 0]
                   end

    {
      "successful_results" => times.size,
      "repeat_noise_floor_ratio" => noise_floor,
      "cluster_count" => cluster_count,
      "cluster_sizes" => segments.map { |start_index, end_index| end_index - start_index },
      "cluster_min_times" => segments.map { |start_index, _end_index| times.fetch(start_index) },
      "cluster_max_times" => cluster_maxima,
      "boundary_gap_ratios" => segments.each_cons(2).map do |left, right|
        times.fetch(right.first) / times.fetch(left.last - 1)
      end,
      "top" => cluster_maxima.fetch(tier_indices.fetch(0)),
      "great" => cluster_maxima.fetch(tier_indices.fetch(1)),
      "good" => cluster_maxima.fetch(tier_indices.fetch(2)),
      "fastest" => times.first,
      "slowest" => times.last
    }
  end

  def optimal_segments(times, eligible, cluster_count)
    logs = times.map { |value| Math.log(value) }
    prefix = [0.0]
    prefix_squares = [0.0]
    logs.each do |value|
      prefix << prefix.last + value
      prefix_squares << prefix_squares.last + value * value
    end
    segment_cost = lambda do |start_index, end_index|
      count = end_index - start_index
      sum = prefix.fetch(end_index) - prefix.fetch(start_index)
      square_sum = prefix_squares.fetch(end_index) - prefix_squares.fetch(start_index)
      square_sum - sum * sum / count
    end

    allowed = [0, *eligible, times.size]
    costs = Array.new(cluster_count + 1) { Hash.new(Float::INFINITY) }
    previous = Array.new(cluster_count + 1) { {} }
    costs[0][0] = 0.0
    (1..cluster_count).each do |clusters|
      allowed.each do |end_index|
        next if end_index.zero?
        allowed.each do |start_index|
          next unless start_index < end_index && costs.fetch(clusters - 1)[start_index].finite?

          candidate = costs.fetch(clusters - 1)[start_index] + segment_cost.call(start_index, end_index)
          next unless candidate < costs.fetch(clusters)[end_index]

          costs.fetch(clusters)[end_index] = candidate
          previous.fetch(clusters)[end_index] = start_index
        end
      end
    end

    end_index = times.size
    segments = cluster_count.downto(1).map do |clusters|
      start_index = previous.fetch(clusters).fetch(end_index)
      segment = [start_index, end_index]
      end_index = start_index
      segment
    end.reverse
    raise "natural-break reconstruction did not cover the cell" unless segments.first.first.zero?

    segments
  end

  def latest_pipeline_amendment_path
    files = Dir.glob(path("pipeline_amendment*.yaml")).select do |file|
      File.basename(file) == "pipeline_amendment.yaml" || File.basename(file).match?(/\Apipeline_amendment\.\d+\.yaml\z/)
    end
    files.max_by do |file|
      name = File.basename(file)
      name == "pipeline_amendment.yaml" ? 1 : Integer(name.match(/\.(\d+)\.yaml\z/)[1], 10)
    end || raise("pipeline amendment not found")
  end

  def atomic_write(destination, content)
    FileUtils.mkdir_p(File.dirname(destination))
    temporary = "#{destination}.tmp-#{Process.pid}"
    File.write(temporary, content, mode: "wb")
    File.rename(temporary, destination)
  ensure
    FileUtils.rm_f(temporary) if defined?(temporary)
  end

  def sha256(file)
    Digest::SHA256.file(file).hexdigest
  end

  def path(*parts)
    File.join(@run_dir, *parts)
  end
end

if $PROGRAM_NAME == __FILE__
  options = { dry_run: false }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby tools/timing_audit/bin/scoring_threshold_review.rb --run-dir=PATH [--dry-run]"
    opts.on("--run-dir=PATH", "Completed local-evaluation run") { |value| options[:run_dir] = value }
    opts.on("--dry-run", "Review inputs without writing thresholds") { options[:dry_run] = true }
  end
  parser.parse!
  abort parser.to_s unless options[:run_dir]
  ScoringThresholdReview.new(**options).run
end
