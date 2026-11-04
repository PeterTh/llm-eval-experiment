# frozen_string_literal: true
require_relative 'inventory'

module ValidationAudit
  module MethodSnapshot
    module_function

    def save(evidence, label)
      raise 'Unsafe method label' unless label.match?(/\A[a-z0-9-]+\z/)
      root = File.expand_path('../..', __dir__)
      names = %w[validation_helper.rb lib/local_evaluation/comparison_policy.rb
        lib/local_evaluation/validation_pipeline.rb lib/local_evaluation/external_validation_cases.rb
        lib/local_evaluation/shape_validation_cases.rb]
      names += Dir[File.join(__dir__, '*.rb')].map { |path| path.delete_prefix(root + '/') }
      files = names.sort.to_h { |relative| [relative, File.binread(File.join(root, relative))] }
      manifest = { 'baseline_commit' => ValidationAudit.git(root, 'rev-parse', 'HEAD').strip,
        'files_sha256' => files.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) } }
      destination = File.join(evidence, 'method', label)
      if File.file?(File.join(destination, 'manifest.json'))
        raise 'Pilot method changed' unless ValidationAudit.read(File.join(destination, 'manifest.json')) == manifest
        files.each_key do |relative|
          raise 'Saved pilot method changed' unless ValidationAudit.sha(File.join(destination, relative)) == manifest.fetch('files_sha256').fetch(relative)
        end
        return manifest
      end
      raise 'Incomplete method snapshot needs investigation' if File.exist?(destination)
      files.each do |relative, bytes|
        path = File.join(destination, relative)
        FileUtils.mkdir_p(File.dirname(path))
        LocalEvaluation.atomic_write(path, bytes)
      end
      ValidationAudit.save(File.join(destination, 'manifest.json'), manifest)
      manifest
    end
  end
end
