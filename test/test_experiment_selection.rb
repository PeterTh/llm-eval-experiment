require "minitest/autorun"
require "tmpdir"
require_relative "../lib/experiment_selection"

class ExperimentSelectionTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("experiment-selection-", "/tmp")
    @configurations = ExperimentSelection.configurations(benchmarks: %w[black-scholes matmul],
      models: ["claude-opus-5.5-cc-medium"], backends: %w[omp cuda mpi hybrid], repetitions: 5)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def select_ids(ids)
    path = File.join(@directory, "ids.txt")
    File.write(path, ids.join("\n") + "\n")
    ExperimentSelection.select(@configurations, path: path)
  end

  def test_full_scope_and_original_execution_order
    assert_equal 40, @configurations.size
    assert_equal ["black-scholes", "claude-opus-5.5-cc-medium", "omp", 1], @configurations.first
    assert_equal ["matmul", "claude-opus-5.5-cc-medium", "hybrid", 5], @configurations.last
    assert_same @configurations, ExperimentSelection.select(@configurations)
  end

  def test_one_production_observation_keeps_its_identity
    id = "black-scholes_claude-opus-5.5-cc-medium_omp_r1"
    selected = select_ids([id])
    assert_equal [@configurations.first], selected
    assert_equal id, ExperimentSelection.id(selected.first)
  end

  def test_selection_preserves_campaign_order_not_file_order
    assert_equal [@configurations.first, @configurations.last], select_ids([
      ExperimentSelection.id(@configurations.last), ExperimentSelection.id(@configurations.first)])
  end

  def test_unknown_duplicate_and_empty_selections_fail
    id = ExperimentSelection.id(@configurations.first)
    [["unknown"], [id, id], [], [id, ""]].each do |ids|
      assert_raises(ArgumentError) { select_ids(ids) }
    end
  end

  def test_absent_selection_file_fails
    assert_raises(Errno::ENOENT) { ExperimentSelection.select(@configurations, path: File.join(@directory, "missing")) }
  end

  def test_completed_observation_is_detected_without_rewriting_it
    assert_nil ExperimentSelection.completed_duration(@directory)
    path = File.join(@directory, "timing.txt")
    original = "Start time: retained\nEnd time: retained\nDuration: 12.34 seconds\n"
    File.write(path, original)
    assert_equal 12.34, ExperimentSelection.completed_duration(@directory)
    assert_equal original, File.read(path)
    assert_equal [], @configurations.first(1).reject { ExperimentSelection.completed_duration(@directory) }
  end

  def test_corrupt_completion_is_not_silently_skipped_or_reexecuted
    ["", "Duration: NaN seconds\n", "Duration: -1 seconds\n", "Duration: nope seconds\n"].each do |value|
      File.write(File.join(@directory, "timing.txt"), value)
      assert_raises(ArgumentError) { ExperimentSelection.completed_duration(@directory) }
    end
  end
end
