# frozen_string_literal: true

module ValidationAudit
  # The caller owns the host lock and all bookkeeping. Each worker writes only
  # its own immutable result/log paths. Always drain a wave before propagating
  # an error, so another job is never abandoned or mistaken for a completed run.
  module ParallelBatch
    module_function

    def run(jobs)
      raise ArgumentError, 'A validation wave must contain one to four jobs' unless (1..4).cover?(jobs.size)
      workers = jobs.each_with_index.map do |job, index|
        Thread.new do
          Thread.current.report_on_exception = false
          begin
            { value: yield(job, index) }
          rescue Exception => error
            { error: error }
          end
        end
      end
      replies = workers.map(&:value)
      failure = replies.find { |reply| reply[:error] }
      raise failure.fetch(:error) if failure
      replies.map { |reply| reply.fetch(:value) }
    ensure
      workers&.each(&:join)
    end
  end
end
