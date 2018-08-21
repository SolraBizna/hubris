local declared = {}
function globals(...)
   for _,v in ipairs{...} do
      declared[v] = true
   end
end

-- require ahead so that we fail as early as possible if the libraries aren't
-- available, and so that our global system isn't in place to potentially foul
-- them up
require "lpeg"
require "lfs"

local _mt = {}
function _mt:__newindex(k,v)
   if not declared[k] then
      error("Undeclared global: "..tostring(k), 2)
   else
      rawset(self,k,v)
   end
end
_mt.__index = _mt.__newindex
setmetatable(_G, _mt)

globals("DIRSEP", "print_memory_usage", "should_print_call_graph",
        "should_print_dead_routines", "should_print_variable_assignments",
        "should_print_exclusion_sets", "should_print_region_utilization",
        "should_clobber_accumulator_on_intercalls", "outdir", "indirs")

DIRSEP = assert(package.config:match("[^\n]+"))
function print_memory_usage() end
should_print_call_graph = false
should_print_dead_routines = false
should_print_variable_assignments = false
should_print_exclusion_sets = false
should_print_region_utilization = false
should_clobber_accumulator_on_intercalls = false

-- Parse command line options
local n = 1
local cmdline_bad = false
while n <= #arg do
   if arg[n] == "--" then
      table.remove(arg, n)
      break
   elseif arg[n]:sub(1,1) == "-" then
      local opts = table.remove(arg, n)
      for n=2,#opts do
         local opt = opts:sub(n,n)
         if opt == "a" then
            should_print_variable_assignments = true
         elseif opt == "c" then
            should_print_call_graph = true
         elseif opt == "d" then
            should_print_dead_routines = true
         elseif opt == "e" then
            should_print_exclusion_sets = true
         elseif opt == "i" then
            should_clobber_accumulator_on_intercalls = true
         elseif opt == "m" then
            function print_memory_usage(section)
               local mem_pre = collectgarbage "count"
               collectgarbage "collect"
               local mem_post = collectgarbage "count"
               print(("Memory at %9s: %6i KiB -> collect -> %6i KiB")
                     :format(section, math.ceil(mem_pre), math.ceil(mem_post)))
            end
         elseif opt == "r" then
            should_print_region_utilization = true
         else
            io.stderr:write("Unknown option: ",opt,"\n")
            cmdline_bad = true
         end
      end
   else
      n = n + 1
   end
end

if cmdline_bad or #arg < 2 then
   io.write[[
Usage: hubris [options] output_dir input_dir1 [input_dir2 ...]

output_dir really should be empty or nonexistent at the start of the run

Options:
-a: Print the locations of every variable after they are assigned
-c: Print the call graph after the connect pass
-d: Print information about dead routines
-e: Print exclusion set info for routines
-i: Clobber the accumulator on all INTER calls, even those that are not also
      long calls (leave this on during development, but compile without it for
      release)
-m: Print memory usage statistics after each pass
-r: Print region allocation statistics
]]
   os.exit(1)
end

outdir = table.remove(arg, 1)
indirs = arg
