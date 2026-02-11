## Helper for valdiating two outputs against each other

# General shape:
# === RESULTS ===
# Name: ClusterMembership
# Elements: 1000
# Sum: 2.98470000000000000e+04
# Min: 0.00000000000000000e+00
# Max: 1.10000000000000000e+02
# Sample[0]: 1.00000000000000000e+00
# Sample[250]: 3.00000000000000000e+00
# Sample[500]: 0.00000000000000000e+00
# Sample[750]: 3.00000000000000000e+00
# Sample[999]: 1.30000000000000000e+01
# Hash: dbef3881b0a560cd
# === END RESULTS ===

def validate(ref_output, validation_output)
    # find the results section in the validation output
    get_output = lambda do |output|
        if output.include?("=== RESULTS ===") && output.include?("=== END RESULTS ===")
            return output.split("=== RESULTS ===")[1].split("=== END RESULTS ===")[0].strip
        else
            return [false, "Output does not contain results section with expected format."]
        end
    end
    ref_results = get_output.call(ref_output)
    validation_results = get_output.call(validation_output)

    # iterate over each object
    ref_objects = ref_results.split("Name: ").drop(1) # split by object and drop the first empty part
    validation_objects = validation_results.split("Name: ").drop(1)

    if ref_objects.size != validation_objects.size
        return [false, "Number of objects in validation output (#{validation_objects.size}) does not match reference output (#{ref_objects.size})."]
    end

    ret_string = ""
    ref_objects.zip(validation_objects).each do |ref_obj, val_obj|
        ref_lines = ref_obj.split("\n").map(&:strip)
        val_lines = val_obj.split("\n").map(&:strip)

        if ref_lines.size != val_lines.size
            return [false, "Number of lines for object #{ref_lines[0]} does not match between validation and reference output."]
        end

        hash_same = false
        ref_lines.zip(val_lines).each do |ref_line, val_line|
            # hash match is not required
            if ref_line.start_with?("Hash: ")
                hash_same = (ref_line == val_line)
                next
            end
            # element count must match exactly
            if ref_line.start_with?("Elements: ")
                if ref_line != val_line
                    return [false, "Element count mismatch for object #{ref_lines[0]}: '#{ref_line}' vs '#{val_line}'"]
                end
                next
            end
            if ref_line != val_line
                epsilon = 1e-5
                # try to parse numbers and compare with tolerance
                ref_value = ref_line.split(": ")[1]
                val_value = val_line.split(": ")[1]
                if ref_value.nil? || val_value.nil?
                    return [false, "Line format mismatch for object #{ref_lines[0]}: '#{ref_line}' vs '#{val_line}'"]
                end
                begin
                    ref_num = Float(ref_value)
                    val_num = Float(val_value)
                    if (ref_num - val_num).abs > epsilon
                        return [false, "Numeric value mismatch for object #{ref_lines[0]}: '#{ref_line}' vs '#{val_line}'"]
                    end
                rescue ArgumentError
                    return [false, "Non-numeric value mismatch for object #{ref_lines[0]}: '#{ref_line}' vs '#{val_line}'"]
                end
            end
        end
        ret_string += " - Object #{ref_lines[0]}: PASSED (hash match: #{hash_same})\n"
    end

    return [true, "Validation successful. All objects match reference output.\n#{ret_string}"]
end
