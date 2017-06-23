globals("compiler_error", "maybe_error_exit", "num_errors", "include_stack")

local last_error_file = false
include_stack = {}
num_errors = 0

function compiler_error(current_file, current_line, format, ...)
   if current_file ~= last_error_file then
      if current_file then
         io.stderr:write("In file ", current_file, ":\n")
         for n=#include_stack,1,-1 do
            io.stderr:write("(included from ",include_stack[n],")\n")
         end
      else
         assert(#include_stack == 0)
         io.stderr:write("In no particular file:\n")
      end
      last_error_file = current_file
   end
   if current_line then
      io.stderr:write("Line ", current_line, ": ")
   end
   io.stderr:write(format:format(...), "\n")
   num_errors = num_errors + 1
end

function maybe_error_exit()
   -- if errors occurred, report and exit
   if num_errors > 0 then
      if num_errors == 1 then
         io.stderr:write("Compile failed, ",num_errors," error\n")
      else
         io.stderr:write("Compile failed, ",num_errors," errors\n")
      end
      os.exit(1)
   end
end
