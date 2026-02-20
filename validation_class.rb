
class ValidationResult
    attr_accessor :basic_para, :validation_build, :validation_run, :internal_validation, :output_comparison, :err_string
    attr_reader :benchmark, :model, :par_type, :run
    
    def initialize(benchmark, model, par_type, run)
        @basic_para = false
        @validation_build = false
        @validation_run = false
        @internal_validation = false
        @output_comparison = false
        @err_string = ""
        @benchmark = benchmark
        @model = model
        @par_type = par_type
        @run = run
    end

    # provide a one-line console summary with emojis for quick overview of which validation steps passed or failed
    def summary
        summary_str = "%12s | %10s | %6s | %d : " % [@benchmark, @model, @par_type, @run]
        summary_str += @basic_para ? "✅ Para " : "❌ Para "
        summary_str += @validation_build ? "✅ Build " : "❌ Build " if @basic_para
        summary_str += @validation_run ? "✅ Run " : "❌ Run " if @validation_build
        summary_str += @internal_validation ? "✅ Validation " : "❌ Validation " if @validation_run
        summary_str += @output_comparison ? "✅ Comparison" : "❌ Comparison" if @internal_validation
        return summary_str
    end

    def is_for(benchmark, model, par_type, run)
        return @benchmark == benchmark && @model == model && @par_type == par_type && @run == run
    end

    def id_string
        return run_id_string(@benchmark, @model, @par_type, @run)
    end
end
