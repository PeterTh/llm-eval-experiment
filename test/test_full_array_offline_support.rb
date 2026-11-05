# frozen_string_literal: true
require 'minitest/autorun'
require 'open3'
require_relative '../tools/validation_audit/full_array_capture'
require_relative '../tools/validation_audit/full_array_offline_support'

class FullArrayOfflineSupportTest < Minitest::Test
  Offline = ValidationAudit::FullArrayOffline
  Capture = ValidationAudit::FullArrayCapture

  def test_replay_numerics_are_the_frozen_observer_implementation
    directory = File.expand_path('../tools/validation_audit', __dir__)
    capture = File.read(File.join(directory, 'full_array_capture.rb'))
    offline = File.read(File.join(directory, 'full_array_offline_support.rb'))
    methods = capture[capture.index('    def fnv(')...capture.index('    def capture(')]
    assert_includes offline, methods
    assert_equal Capture::SYMBOLS, Offline::SYMBOLS
    assert_equal Capture::HASH_SHA, Offline::HASH_SHA
    samples = [[[], [], 0], [[1, 2], [1, 3], 0], [[1.0, 2.0], [1.0, 7.0], 5.0],
      [[1.0], [1.00001], 1e-5], [[1.0], [Float::NAN], 1e-5],
      [[1.0], [Float::INFINITY], 1e-5]]
    samples.each do |expected, actual, epsilon|
      assert_equal Capture.compare_values(expected, actual, epsilon: epsilon),
        Offline.compare_values(expected, actual, epsilon: epsilon)
    end
  end

  def test_offline_import_does_not_load_the_execution_stack
    path = File.expand_path('../tools/validation_audit/verify_full_array_full_export.rb', __dir__)
    code = "require ARGV.fetch(0); abort 'execution stack loaded' if defined?(ValidationAudit::Runner) || defined?(LocalEvaluation::ProcessRunner); puts 'read-only'"
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-e', code, path)
    assert status.success?, stderr
    assert_equal "read-only\n", stdout
  end
end
