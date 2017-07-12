#!/usr/bin/env lua5.3

-- This file is concatentated from several smaller files, to allow the
-- program's logic to be spread out without complicating its invocation
-- and/or distribution processes.

load("local declared = {}\
function globals(...)\
   for _,v in ipairs{...} do\
      declared[v] = true\
   end\
end\
\
-- require ahead so that we fail as early as possible if the libraries aren't\
-- available, and so that our global system isn't in place to potentially foul\
-- them up\
require \"lpeg\"\
require \"lfs\"\
\
local _mt = {}\
function _mt:__newindex(k,v)\
   if not declared[k] then\
      error(\"Undeclared global: \"..tostring(k), 2)\
   else\
      rawset(self,k,v)\
   end\
end\
_mt.__index = _mt.__newindex\
setmetatable(_G, _mt)\
\
globals(\"DIRSEP\", \"print_memory_usage\", \"should_print_call_graph\",\
        \"should_print_dead_routines\", \"should_print_variable_assignments\",\
        \"should_print_exclusion_sets\",\
        \"should_clobber_accumulator_on_intercalls\", \"outdir\", \"indirs\")\
\
DIRSEP = assert(package.config:match(\"[^\\n]+\"))\
function print_memory_usage() end\
should_print_call_graph = false\
should_print_dead_routines = false\
should_print_variable_assignments = false\
should_print_exclusion_sets = false\
should_clobber_accumulator_on_intercalls = false\
\
-- Parse command line options\
local n = 1\
local cmdline_bad = false\
while n <= #arg do\
   if arg[n] == \"--\" then\
      table.remove(arg, n)\
      break\
   elseif arg[n]:sub(1,1) == \"-\" then\
      local opts = table.remove(arg, n)\
      for n=2,#opts do\
         local opt = opts:sub(n,n)\
         if opt == \"m\" then\
            function print_memory_usage(section)\
               local mem_pre = collectgarbage \"count\"\
               collectgarbage \"collect\"\
               local mem_post = collectgarbage \"count\"\
               print((\"Memory at %9s: %6i KiB -> collect -> %6i KiB\")\
                     :format(section, math.ceil(mem_pre), math.ceil(mem_post)))\
            end\
         elseif opt == \"c\" then\
            should_print_call_graph = true\
         elseif opt == \"d\" then\
            should_print_dead_routines = true\
         elseif opt == \"e\" then\
            should_print_exclusion_sets = true\
         elseif opt == \"a\" then\
            should_print_variable_assignments = true\
         elseif opt == \"i\" then\
            should_clobber_accumulator_on_intercalls = true\
         else\
            io.stderr:write(\"Unknown option: \"..opt)\
            cmdline_bad = true\
         end\
      end\
   else\
      n = n + 1\
   end\
end\
\
if cmdline_bad or #arg < 2 then\
   io.write[[\
Usage: hubris [options] output_dir input_dir1 [input_dir2 ...]\
\
output_dir really should be empty or nonexistent at the start of the run\
\
Options:\
-a: Print the locations of every variable after they are assigned\
-c: Print the call graph after the connect pass\
-d: Print information about dead routines\
-e: Print exclusion set info for routines\
-i: Clobber the accumulator on all INTER calls, even those that are not also\
      long calls (leave this on during development, but compile without it for\
      release)\
-m: Print memory usage statistics after each pass\
]]\
   os.exit(1)\
end\
\
outdir = table.remove(arg, 1)\
indirs = arg\
","@src/top.lua")()
load("local bitset = {}\
local INT_BITS = 1\
while 1 << INT_BITS ~= 0 do INT_BITS = INT_BITS << 1 end\
assert(INT_BITS & (INT_BITS - 1) == 0, \"non power of two INT_BITS\")\
local INT_SHIFT = 0\
while 1 << INT_SHIFT ~= INT_BITS do INT_SHIFT = INT_SHIFT + 1 end\
local INT_MASK = INT_BITS - 1\
\
bitset._mt = {__index={}}\
function bitset._mt.__index:set(n)\
   local int = (n >> INT_SHIFT) + 1\
   local bit = 1 << (n & INT_MASK)\
   self[int] = self[int] | bit\
end\
function bitset._mt.__index:unset(n)\
   local int = (n >> INT_SHIFT) + 1\
   local bit = 1 << (n & INT_MASK)\
   self[int] = self[int] & ~bit\
end\
function bitset._mt.__index:get(n)\
   local int = (n >> INT_SHIFT) + 1\
   local bit = 1 << (n & INT_MASK)\
   return self[int] & bit ~= 0\
end\
function bitset._mt.__index:union(other)\
   assert(other.count == self.count, \"union requires both sets to have the same count\")\
   for n=1,self.intcount do\
      self[n] = self[n] | other[n]\
   end\
end\
function bitset._mt.__index:popcount()\
   -- \"sparse ones\" algorithm\
   local pop = 0\
   for n=1,self.intcount do\
      local m = self[n]\
      while m ~= 0 do\
         m = m & (m - 1)\
         pop = pop + 1\
      end\
   end\
   return pop\
end\
function bitset._mt.__index:any_bits_in_common(other)\
   assert(other.count == self.count, \"union requires both sets to have the same count\")\
   for n=1,self.intcount do\
      if self[n] & other[n] ~= 0 then return true end\
   end\
   return false\
end\
function bitset._mt.__index:write(f)\
   for n=0,self.count-1 do\
      if self:get(n) then io.write(\"1\") else io.write(\"0\") end\
   end\
end\
\
function bitset.new(count)\
   local ret = {}\
   setmetatable(ret, bitset._mt)\
   ret.count = count\
   local intcount = (count + INT_BITS - 1) >> INT_SHIFT\
   ret.intcount = intcount\
   for n=1,intcount do ret[n] = 0 end\
   return ret\
end\
\
globals(\"bitset\")\
_G.bitset = bitset\
","@src/bitset.lua")()
load("globals(\"make_directories_leading_up_to\")\
\
local lfs = require \"lfs\"\
\
local dirs_okay = {}\
function make_directories_leading_up_to(path)\
   -- this will behave a little strangely in some cases on Windows, in\
   -- particular if the output directory is an absolute path on a drive letter\
   -- that does not exist\
   -- strip trailing DIRSEPs\
   local n = #path\
   while path:sub(n,n) == DIRSEP do\
      n = n - 1\
   end\
   -- skip down to the next DIRSEP, if any\
   while n > 0 and path:sub(n,n) ~= DIRSEP do\
      n = n - 1\
   end\
   -- either \"/\" or \"\" is all that is left\
   if n <= 1 then return end\
   local dir = path:sub(1,n)\
   -- is this already a directory?\
   -- (save a system call maybe)\
   if dirs_okay[dir] then return true end\
   local st = lfs.attributes(dir, \"mode\")\
   if st == \"directory\" then\
      dirs_okay[dir] = true\
   elseif st ~= nil then\
      return -- let a future error handle this...\
   else\
      if not lfs.mkdir(dir) then\
         make_directories_leading_up_to(dir)\
         assert(lfs.mkdir(dir))\
      end\
      dirs_okay[dir] = true\
   end\
end\
","@src/mdlut.lua")()
load("globals(\"compiler_error\", \"maybe_error_exit\", \"num_errors\", \"include_stack\")\
\
local last_error_file = false\
include_stack = {}\
num_errors = 0\
\
function compiler_error(current_file, current_line, format, ...)\
   if current_file ~= last_error_file then\
      if current_file then\
         io.stderr:write(\"In file \", current_file, \":\\n\")\
         for n=#include_stack,1,-1 do\
            io.stderr:write(\"(included from \",include_stack[n],\")\\n\")\
         end\
      else\
         assert(#include_stack == 0)\
         io.stderr:write(\"In no particular file:\\n\")\
      end\
      last_error_file = current_file\
   end\
   if current_line then\
      io.stderr:write(\"Line \", current_line, \": \")\
   end\
   io.stderr:write(format:format(...), \"\\n\")\
   num_errors = num_errors + 1\
end\
\
function maybe_error_exit()\
   -- if errors occurred, report and exit\
   if num_errors > 0 then\
      if num_errors == 1 then\
         io.stderr:write(\"Compile failed, \",num_errors,\" error\\n\")\
      else\
         io.stderr:write(\"Compile failed, \",num_errors,\" errors\\n\")\
      end\
      os.exit(1)\
   end\
end\
","@src/error.lua")()
load("local lpeg = require \"lpeg\"\
\
globals(\"identifier_mangling_function\",\"identifier_creating_function\",\
        \"active_routine\",\"program_globals\",\"imangle_errors\",\"resolve_flag\")\
\
function identifier_mangling_function(id)\
   if active_routine then\
      local proutine,var = lpeg.match(parent_routine_extractor, id)\
      if proutine and active_routine.callees[proutine]\
         and active_routine.callees[proutine].vars[var]\
         and active_routine.callees[proutine].vars[var].param then\
         return active_routine.callees[proutine].vars[var].location\
      end\
      if active_routine.vars[id] then\
         return active_routine.vars[id].location\
      end\
      local scope = active_routine.parent_scope\
      while scope do\
         if scope.vars[id]\
         and (scope.vars[id].param or scope.vars[id].sublocal) then\
            return scope.vars[id].location\
         end\
         scope = scope.parent_scope\
      end\
   end\
   if program_globals[id] then\
      return program_globals[id].location\
   end\
   return id\
   --[[\
   if not imangle_errors then\
      imangle_errors = {}\
   end\
   table.insert(imangle_errors, id)\
   return \"__INVALID__\"\
   ]]\
end\
function resolve_flag(id)\
   if active_routine then\
      local proutine,flag = lpeg.match(parent_routine_extractor, id)\
      if proutine and active_routine.callees[proutine]\
         and active_routine.callees[proutine].flags[flag]\
         and active_routine.callees[proutine].flags[flag].param then\
            return active_routine.callees[proutine].flags[flag].var,\
            active_routine.callees[proutine].flags[flag].bit\
      end\
      if active_routine.flags[id] then\
         return active_routine.flags[id].var, active_routine.flags[id].bit\
      end\
      local scope = active_routine.parent_scope\
      while scope do\
         if scope.flags[id]\
         and (scope.flags[id].param or scope.flags[id].sublocal) then\
            return scope.flags[id].var, scope.flags[id].bit\
         end\
         scope = scope.parent_scope\
      end\
   end\
   if program_global_flags[id] then\
      return program_global_flags[id].var, program_global_flags[id].bit\
   end\
end\
function identifier_creating_function(id)\
   -- not actually using this right now\
   return id\
end\
","@src/imangler.lua")()
load("globals(\"directive_tester\",\"directive_matcher\",\"comment_stripper\",\
        \"identifier_mangler\",\"identifier_matcher\",\"blank_line_tester\",\
        \"value_extractor\",\"varsize_matcher\",\"good_label_matcher\",\
        \"routine_name_validator\",\"parent_routine_extractor\")\
local lpeg = require \"lpeg\"\
local C,Ct,Cc,S,P,R = lpeg.C,lpeg.Ct,lpeg.Cc,lpeg.S,lpeg.P,lpeg.R\
-- general-purpose bits\
local whitespace = S\" \\t\"\
local EW = whitespace^0 -- EW -> eat whitespace\
identifier_matcher = ((P\"_\"+P\"\\\\@\"+R(\"az\",\"AZ\")))*(P\"_\"+P\"\\\\@\"+R(\"az\",\"AZ\",\"09\"))^0\
blank_line_tester = whitespace^0 * -1;\
local scoped_id = (identifier_matcher*\"::\")^0*identifier_matcher\
local quoted_char = P\"\\\\\" * 1 + 1\
local dblquote_string = P'\"' * (quoted_char - P'\"')^0 * P'\"'\
local quote_string = P\"'\" * (quoted_char - P\"'\")^0 * P\"'\"\
-- directive_tester\
directive_tester = EW * \"#\"\
-- directive_matcher\
local parsed_quoted_char = (P\"\\\\\" * C(1))\
local parsed_dblquote_string = Ct(P'\"' * ((parsed_quoted_char + C(1)) - P'\"')^0 * P'\"') / table.concat\
local directive_param = EW * (parsed_dblquote_string + C((1-S\", \\t\")^1))\
   * (EW * \",\" + #whitespace * EW + -1)\
directive_matcher = EW * \"#\" * EW * C(identifier_matcher)\
   * Ct(directive_param^0) * -1\
-- comment_stripper\
local noncomment_char = dblquote_string + quote_string + (1 - P\";\");\
comment_stripper = C(noncomment_char^0)\
-- identifier_mangler\
local mangled_scoped_id = C(scoped_id)/identifier_mangling_function\
local mangled_new_id = C(identifier_matcher)/identifier_creating_function\
identifier_mangler = Ct(\
   -- label definitions get mangled differently\
   ((mangled_scoped_id*(C\":\"+#whitespace+-1))+true)\
      *(mangled_scoped_id+C(whitespace^1+quote_string+dblquote_string+1))^0\
      * -1\
)/table.concat\
-- value_extractor\
local hex_value = lpeg.P\"$\" * C(lpeg.R(\"09\",\"AF\",\"af\")*lpeg.R(\"09\",\"AF\",\"af\")^-3) * Cc(16) / tonumber\
local dec_value = C(lpeg.R\"09\"*lpeg.R\"09\"^-4) * Cc(10) / tonumber\
value_extractor = hex_value + dec_value\
-- varsize_matcher\
local function rep(x) return x, x end\
local sbs_matcher = value_extractor * \"*\" * value_extractor * \"/\" * value_extractor\
local ss_matcher = value_extractor * Cc(1) * \"/\" * value_extractor\
local s_matcher = value_extractor / rep * Cc(0)\
varsize_matcher = ((\"BYTE\" * Cc(1) * Cc(1) * Cc(0))\
      + ((\"WORD\"+P\"PTR\") * Cc(2) * Cc(2) * Cc(0))\
      + sbs_matcher + ss_matcher + s_matcher) * -1\
-- good_label_matcher\
good_label_matcher = P\"+\"^1+P\"-\"^1+identifier_matcher\
-- routine_name_validator\
local routine_name = identifier_matcher - \"_\"\
routine_name_validator = ((routine_name * P\"::\") - (routine_name*-1))^0 * routine_name * -1\
-- parent_routine_extractor\
parent_routine_extractor = C(((routine_name * P\"::\") - (routine_name*P\"::\"*routine_name*-1))^0 * routine_name) * P\"::\" * C(routine_name) * -1\
","@src/grammar.lua")()
load("globals(\"asm_files\", \"routines\", \"entry_points\", \"tracked_registers\",\
        \"memory_regions\", \"do_eat_pass\", \"program_global_flags\",\
        \"slot_aliases\", \"groups\", \"bs\", \"bankcount\")\
\
local lpeg = require \"lpeg\"\
local current_file, current_line\
local function eat_error(...)\
   return compiler_error(current_file, current_line, ...)\
end\
\
asm_files = {}\
routines = {}\
entry_points = {}\
tracked_registers = {\
   A={name=\"A\",push=\"PHA\",pull=\"PLA\"},\
   X={name=\"X\",push=\"PHX\",pull=\"PLX\"},\
   Y={name=\"Y\",push=\"PHY\",pull=\"PLY\"},\
}\
tracked_registers[1] = tracked_registers.A\
tracked_registers[2] = tracked_registers.X\
tracked_registers[3] = tracked_registers.Y\
program_globals = {}\
program_global_flags = {}\
slot_aliases = {}\
groups = {}\
memory_regions = {}\
local current_routine\
local stop_parsing_file\
local add_lines_from\
\
local function variable(dest_table, vardata, params)\
   vardata.file = current_file\
   vardata.line = current_line\
   if #params < 3 then\
      eat_error(\"Not enough parameters for variable directive (#... size name location)\")\
      return\
   end\
   vardata.location = table.remove(params, 1)\
   if not lpeg.match(identifier_matcher, vardata.location) then\
      vardata.location = lpeg.match(value_extractor, vardata.location)\
      if not vardata.location then\
         eat_error(\"Location value is invalid\")\
         return\
      end\
   end\
   vardata.size, vardata.block, vardata.stride = lpeg.match(varsize_matcher, table.remove(params, 1))\
   if not vardata.size then\
      eat_error(\"Size value is invalid\")\
      return\
   end\
   vardata.overhead = (vardata.size + vardata.block - 1) // vardata.block\
      * vardata.stride + vardata.size\
   vardata.name = table.remove(params, 1)\
   if not lpeg.match(identifier_matcher * -1, vardata.name) then\
      eat_error(\"Variable name is not a valid identifier\")\
      return\
   end\
   if dest_table[vardata.name] then\
      eat_error(\"Duplicate variable definition for %q\", vardata.name)\
      return\
   end\
   while #params > 0 do\
      local next_param = table.remove(params, 1)\
      if next_param == \"PERSIST\" then\
         if vardata.persist then\
            eat_error(\"Redundant PERSIST tag\")\
         end\
         vardata.persist = true\
      else\
         eat_error(\"unhandled variable tag: %s\", next_param)\
      end\
   end\
   dest_table[vardata.name] = vardata\
end\
\
local function flag(dest_table, flagdata, params)\
   flagdata.file = current_file\
   flagdata.line = current_line\
   if #params < 1 then\
      eat_error(\"Not enough parameters for flag directive (#... name)\")\
      return\
   end\
   flagdata.name = table.remove(params, 1)\
   if not lpeg.match(identifier_matcher * -1, flagdata.name) then\
      eat_error(\"Flag name is not a valid identifier\")\
      return\
   end\
   if dest_table[flagdata.name] then\
      eat_error(\"Duplicate flag definition for %q\", flagdata.name)\
      return\
   end\
   while #params > 0 do\
      local next_param = table.remove(params, 1)\
      if next_param == \"PERSIST\" then\
         if flagdata.persist then\
            eat_error(\"Redundant PERSIST tag\")\
         end\
         flagdata.persist = true\
      else\
         eat_error(\"unhandled flag tag: %s\", next_param)\
      end\
   end\
   dest_table[flagdata.name] = flagdata\
end\
\
local directives = {}\
function directives.include(params)\
   if #params ~= 1 then\
      eat_error(\"#include requires exactly one parameter\")\
      return\
   end\
   local path = params[1]\
   if DIRSEP ~= \"/\" then path = path:gsub(\"/\", DIRSEP) end\
   local f,found_path\
   for n=1,#indirs do\
      found_path = indirs[n]..DIRSEP..path\
      f = io.open(found_path, \"rb\")\
      if f then break end\
   end\
   if not f then\
      eat_error(\"unable to locate file: %q\", path)\
      return\
   end\
   local old_current_file, old_current_line = current_file, current_line\
   table.insert(include_stack, old_current_file..\":\"..old_current_line)\
   current_file, current_line = found_path, 1\
   add_lines_from(f)\
   table.remove(include_stack)\
   current_file, current_line = old_current_file, old_current_line\
   f:close()\
end\
function directives.global(params)\
   return variable(program_globals, {persist=true}, params)\
end\
directives[\"local\"] = function(params)\
   return variable(current_routine.vars, {routine=current_routine}, params)\
end\
function directives.sublocal(params)\
   return variable(current_routine.vars, {routine=current_routine,sublocal=true}, params)\
end\
function directives.param(params)\
   return variable(current_routine.vars, {routine=current_routine,param=true}, params)\
end\
function directives.globalflag(params)\
   return flag(program_global_flags, {persist=true}, params)\
end\
function directives.localflag(params)\
   return flag(current_routine.flags, {routine=current_routine}, params)\
end\
function directives.sublocalflag(params)\
   return flag(current_routine.flags, {routine=current_routine,sublocal=true}, params)\
end\
function directives.paramflag(params)\
   return flag(current_routine.flags, {routine=current_routine,param=true}, params)\
end\
function directives.bs(params)\
   if #params ~= 1 then\
      eat_error(\"#bs requires exactly one argument\")\
   elseif bs ~= nil then\
      eat_error(\"multiple #bs directives cannot coexist\")\
   else\
      bs = tonumber(params[1])\
      if bs == nil or bs|0 ~= bs or bs < 0 or bs > 3 then\
         eat_error(\"invalid #bs value, must be 0--3\")\
         bs = nil\
      end\
   end\
end\
function directives.bankcount(params)\
   if #params ~= 1 then\
      eat_error(\"#bankcount requires exactly one argument\")\
   elseif bankcount ~= nil then\
      eat_error(\"multiple #bankcount directives cannot coexist\")\
   else\
      bankcount = tonumber(params[1])\
      if bankcount == nil or bankcount|0 ~= bankcount or bankcount < 1\
      or (bankcount - 1) & bankcount ~= 0 then\
         eat_error(\"invalid #bankcount value, must be a power of 2 >= 1\")\
         bankcount = nil\
      end\
   end\
end\
function directives.region(params)\
   if #params ~= 3 then\
      eat_error(\"#region needs 3 parameters\")\
      return\
   end\
   local start = lpeg.match(value_extractor, params[1])\
   if not start then\
      eat_error(\"invalid region first-param\")\
      return\
   end\
   local stop = lpeg.match(value_extractor, params[2])\
   if not stop then\
      eat_error(\"invalid region second-param\")\
      return\
   end\
   local name = params[3]\
   if not lpeg.match(identifier_matcher, name) or name == \"ANY\" then\
      eat_error(\"invalid region name\")\
      return\
   end\
   if stop < start then\
      eat_error(\"region stops before it starts\")\
      return\
   end\
   local endut = stop+1\
   for _,region in ipairs(memory_regions) do\
      if start <= region.stop and region.start <= stop then\
         eat_error(\"region overlaps with existing region %q\", region.name)\
      end\
   end\
   memory_regions[#memory_regions+1] = {start=start, stop=stop,\
                                        endut=endut, name=name}\
   memory_regions[name] = memory_regions[#memory_regions]\
end\
function directives.slot(params)\
   if #params ~= 2 then\
      eat_error(\"#slot needs two parameters: the slot number and the name of the slot\")\
   else\
      local slotno = tonumber(params[1])\
      if slotno|0 ~= slotno or slotno < 0 or slotno >= 8 then\
         eat_error(\"absurd slot number\")\
         return\
      end\
      local slotname = params[2]\
      if slot_aliases[slotname] then\
         eat_error(\"multiple #slots named %q exist\", slotname)\
         return\
      end\
      slot_aliases[slotname] = slotno\
   end\
end\
function directives.group(params)\
   if #params ~= 3 then\
      eat_error(\"#group needs three parameters: bank number, slot, and group name\")\
   else\
      local bankno = tonumber(params[1])\
      if bankno|0 ~= bankno or bankno >= 256 or bankno < 0 then\
         eat_error(\"absurd bank number\")\
      elseif groups[params[3]] then\
         eat_error(\"multiple #groups named %q exist\", params[3])\
      else\
         groups[params[3]] = {bank=bankno, slot=params[2], name=params[3],\
                             file=current_file, line=current_line}\
      end\
   end\
end\
function directives.routine(params)\
   if current_routine ~= nil then\
      eat_error(\"previous #routine did not #endroutine yet\")\
      stop_parsing_file = true\
      return\
   elseif #params < 1 then\
      eat_error(\"#routine requires at least one parameter\")\
      stop_parsing_file = true\
      return\
   elseif not lpeg.match(routine_name_validator, params[1]) then\
      eat_error(\"routine name is not valid; must be one or more identifiers (not beginning with _) separated by `::`\")\
      stop_parsing_file = true\
      return\
   elseif routines[params[1]] then\
      eat_error(\"another #routine with the same name already exists\")\
      stop_parsing_file = true\
      return\
   end\
   current_routine = {name=table.remove(params,1), lines={},\
                      file=current_file, start_line=current_line, regs={},\
                      callers={}, callees={}, vars={}, flags={}}\
   routines[current_routine.name] = current_routine\
   local current_register_mode\
   while #params > 0 do\
      local next_param = table.remove(params, 1)\
      if next_param == \"ENTRY\" then\
         if current_routine.is_entry_point then\
            eat_error(\"multiple ENTRY tags on the same #routine are meaningless\")\
         else\
            current_routine.is_entry_point = true\
            entry_points[#entry_points+1] = current_routine\
         end\
      elseif tracked_registers[next_param] then\
         if current_register_mode == nil then\
            eat_error(\"register names in #routine directive must be preceded by CLOBBER or PRESERVE\")\
         elseif current_routine.regs[next_param] ~= nil then\
            eat_error(\"register names cannot occur more than once in the same #routine directive\")\
         else\
            current_routine.regs[next_param] = current_register_mode\
         end\
      elseif next_param == \"CLOBBER\" or next_param == \"PRESERVE\" then\
         current_register_mode = next_param\
      elseif next_param == \"ORGA\" then\
         next_param = table.remove(params, 1)\
         if next_param == nil then\
            eat_error(\"ORGA is missing a parameter\")\
         else\
            local loc = lpeg.match(value_extractor, next_param)\
            if not loc then\
               eat_error(\"ORGA has invalid location\")\
            end\
            current_routine.orga = loc\
         end\
      elseif next_param == \"GROUP\" then\
         next_param = table.remove(params, 1)\
         if next_param == nil then\
            eat_error(\"GROUP is missing a parameter\")\
         elseif current_routine.group then\
            eat_error(\"multiple GROUP tags on the same #routine are meaningless\")\
         else\
            current_routine.group = next_param\
         end\
      else\
         eat_error(\"unhandled #routine tag: %s\", next_param)\
      end\
   end\
end\
function directives.call(params)\
   if #params < 1 then\
      eat_error(\"#call requires a parameter\")\
      return\
   end\
   local pseudoline = {type=\"call\", n=current_line,regs={},\
                       routine=table.remove(params,1)}\
   local current_register_mode\
   while #params > 0 do\
      local next_param = table.remove(params, 1)\
      if tracked_registers[next_param] then\
         if current_register_mode == nil then\
            eat_error(\"register names in #call directive must be preceded by CLOBBER or PRESERVE\")\
         elseif pseudoline.regs[next_param] ~= nil then\
            eat_error(\"register names cannot occur more than once in the same #call directive\")\
         else\
            pseudoline.regs[next_param] = current_register_mode\
         end\
      elseif next_param == \"CLOBBER\" or next_param == \"PRESERVE\" then\
         current_register_mode = next_param\
      elseif next_param == \"JUMP\" then\
         if pseudoline.is_jump then\
            eat_error(\"redundant JUMP tag on #call\")\
         end\
         pseudoline.is_jump = true\
      elseif next_param == \"UNSAFE\" then\
         if pseudoline.unsafe then\
            eat_error(\"redundant UNSAFE tag on #call\")\
         end\
         pseudoline.unsafe = true\
      elseif next_param == \"INTER\" then\
         if pseudoline.inter then\
            eat_error(\"redundant INTER tag on #call\")\
         end\
         pseudoline.inter = true\
      else\
         eat_error(\"unhandled #call tag: %s\", next_param)\
      end\
   end\
   current_routine.lines[#current_routine.lines+1] = pseudoline\
end\
function directives.branchflagset(params)\
   if #params ~= 2 then\
      eat_error(\"#branchflagset requires exactly two parameters\")\
      return\
   end\
   if not lpeg.match(good_label_matcher, params[2]) then\
      eat_error(\"#branchflagset label was not valid\")\
      return\
   end\
   current_routine.lines[#current_routine.lines+1]\
      = {type=\"bfs\", n=current_line, flag=params[1], label=params[2]}\
end\
function directives.branchflagclear(params)\
   if #params ~= 2 then\
      eat_error(\"#branchflagclear requires exactly two parameters\")\
      return\
   end\
   if not lpeg.match(good_label_matcher, params[2]) then\
      eat_error(\"#branchflagclear label was not valid\")\
      return\
   end\
   current_routine.lines[#current_routine.lines+1]\
      = {type=\"bfc\", n=current_line, flag=params[1], label=params[2]}\
end\
directives.branchflagreset = directives.branchflagclear\
function directives.setflag(params)\
   if #params ~= 1 then\
      eat_error(\"#setflag requires exactly one parameter\")\
      return\
   end\
   current_routine.lines[#current_routine.lines+1]\
      = {type=\"setflag\", n=current_line, flag=params[1]}\
end\
function directives.clearflag(params)\
   if #params ~= 1 then\
      eat_error(\"#clearflag requires exactly one parameter\")\
      return\
   end\
   current_routine.lines[#current_routine.lines+1]\
      = {type=\"clearflag\", n=current_line, flag=params[1]}\
end\
directives.resetflag = directives.clearflag\
function directives.begin(params)\
   if #params ~= 0 then\
      eat_error(\"#begin has no parameters\")\
   elseif current_routine.has_begun then\
      eat_error(\"this routine has already had a #begin\")\
      return\
   end\
   current_routine.has_begun = true\
   current_routine.lines[#current_routine.lines+1]\
      = {type=\"begin\",n=current_line}\
end\
directives[\"return\"] = function(params)\
   if #params ~= 0 and (#params ~= 1 or params[1] ~= \"INTERRUPT\") then\
      eat_error(\"`#return` and `#return INTERRUPT` are the only valid #return directives\")\
   end\
   -- multiple #returns are allowed\
   current_routine.has_returned = true\
   current_routine.lines[#current_routine.lines+1]\
      = {type=\"return\",n=current_line,interrupt=params[1] == \"INTERRUPT\"}\
end\
directives.endroutine = function(params)\
   if #params ~= 0 and (#params ~= 1 or params[1] ~= \"NORETURN\") then\
      eat_error(\"`#endroutine` and `#endroutine NORETURN` are the only valid #endroutine directives\")\
   end\
   if not current_routine.has_begun then\
      eat_error(\"#routine lacks a #begin\")\
   end\
   if params[1] ~= \"NORETURN\" and not current_routine.has_returned then\
      eat_error(\"#routine %s lacks a #return directive, and its #endroutine lacks a `NORETURN` tag\", current_routine.name)\
   end\
   current_routine = nil\
end\
function add_lines_from(f)\
   for l in f:lines() do\
      l = lpeg.match(comment_stripper, l)\
      if lpeg.match(directive_tester, l) then\
         local directive, params = lpeg.match(directive_matcher, l)\
         if not directive then\
            eat_error(\"unparseable directive\")\
         elseif directives[directive] then\
            directives[directive](params)\
         else\
            eat_error(\"unknown directive: #%s\", directive)\
         end\
      elseif current_routine then\
         current_routine.lines[#current_routine.lines+1]\
            = {type=\"line\",n=current_line,l=l}\
      elseif not lpeg.match(blank_line_tester, l) then\
         eat_error(\"stray nonblank line\")\
      end\
      current_line = current_line + 1\
      if stop_parsing_file then break end\
   end\
end\
local function eat_file(src)\
   current_file = src\
   current_line = 1\
   stop_parsing_file = false\
   local f = assert(io.open(src, \"rb\"))\
   add_lines_from(f)\
   f:close()\
end\
\
function do_eat_pass()\
   -- First step, gather up all the source files and process them one by one\
   local function recursively_eat_directory(dir)\
      for f in lfs.dir(dir) do\
         if f:sub(1,1) == \".\" then\
            -- ignore this file, it's either a special directory or otherwise\
            -- hidden\
         elseif f:sub(-3,-1) == \".hu\" then\
            -- it's a Hubris source file!\
            eat_file(dir .. DIRSEP .. f)\
         elseif f:sub(-4,-1) == \".65c\" then\
            -- it's a 65C02 source file!\
            asm_files[#asm_files+1] = dir .. DIRSEP .. f\
         elseif lfs.attributes(dir .. DIRSEP .. f, \"mode\") == \"directory\" then\
            -- it's a subdirectory!\
            recursively_eat_directory(dir .. DIRSEP .. f)\
         else\
            -- ignore this file, it's not something we know what to do with\
         end\
      end\
   end\
   for n=1,#indirs do\
      recursively_eat_directory(indirs[n])\
   end\
   current_file, current_line = nil, nil\
end\
","@src/eat_pass.lua")()
load("globals(\"do_memorymap_pass\")\
function do_memorymap_pass()\
   if bs == nil then\
      compiler_error(nil, nil, \"no #bs directive found\")\
      return\
   end\
   if bankcount == nil then\
      compiler_error(nil, nil, \"no #bankcount directive found\")\
      return\
   end\
   -- assign banks and slots\
   for name, group in pairs(groups) do\
      if group.bank >= bankcount then\
         compiler_error(bank.file, bank.line,\
                        \"bank number too large\")\
      end\
      group.slot = slot_aliases[group.slot] or group.slot\
      if type(group.slot) == \"string\" then\
         group.slot = tonumber(group.slot)\
         if not group.slot then\
            compiler_error(group.file, group.line,\
                           \"unknown slot alias\")\
         end\
      end\
      if group.slot then\
         if group.slot|0 ~= group.slot or group.slot >= (1<<bs) then\
            compiler_error(group.file, group.line,\
                           \"slot number out of range\")\
         end\
      end\
   end\
   if num_errors == 0 then\
      -- generate output/memorymap\
      make_directories_leading_up_to(outdir..DIRSEP..\"memorymap\")\
      local f = assert(io.open(outdir..DIRSEP..\"memorymap\", \"w\"))\
      local banksize = 32768 >> bs\
      f:write(\".MEMORYMAP\\nDEFAULTSLOT 0\\n\")\
      for slot=0,(1<<bs)-1 do\
         f:write((\"SLOT %i $%04X $%04X\\n\"):format(slot,\
                                                  32768+banksize*slot,\
                                                  banksize))\
      end\
      f:write(\".ENDME\\n.ROMBANKSIZE \",(\"$%04X\"):format(banksize),\
              \"\\n.ROMBANKS \",bankcount,\"\\n\")\
      local t = {}\
      for name, group in pairs(groups) do\
         t[#t+1] = \".DEFINE hubris_Group_\"..name..\"_bank \"..group.bank..\"\\n\"\
            ..\".DEFINE hubris_Group_\"..name..\"_slot \"..group.slot..\"\\n\"\
      end\
      for name, value in pairs(slot_aliases) do\
         t[#t+1] = \".DEFINE hubris_Slot_\"..name..\"_slot \"..value..\"\\n\"\
      end\
      table.sort(t)\
      for n=1,#t do f:write(t[n]) end\
      f:close()\
      table.sort(memory_regions, function(a,b) return a.start < b.start end)\
   end\
end\
","@src/memorymap_pass.lua")()
load("local lpeg = require \"lpeg\"\
\
globals(\"do_connect_pass\", \"total_number_of_scopes\")\
\
total_number_of_scopes = 0\
\
local function recursively_connect(entry_point, routine, recursion_check)\
   if recursion_check[routine] then\
      compiler_error(routine.file, routine.start_line,\
                     \"Routine %q recurses!\", routine.name)\
      return\
   end\
   if routine.connect_checking then\
      -- following a safe recursion rabbit hole\
      return\
   end\
   if routine.top_scope ~= nil and routine.top_scope ~= entry_point then\
      compiler_error(routine.file, routine.start_line,\
                     \"Routine %q is called from multiple entry points!\",\
                     routine.name)\
      return\
   end\
   if routine.top_scope == nil then\
      if next(routine.vars) ~= nil or next(routine.flags) ~= nil then\
         -- only create scopes for routines that actually have variables\
         routine.scope_number = total_number_of_scopes\
         entry_point.number_of_scopes = entry_point.number_of_scopes + 1\
         total_number_of_scopes = total_number_of_scopes + 1\
      end\
      routine.top_scope = entry_point\
   end\
   local parent_name = lpeg.match(parent_routine_extractor, routine.name)\
   if parent_name then\
      if not routines[parent_name] then\
         compiler_error(routine.file, routine.start_line,\
                        \"Parent routine %q does not exist\", parent_name)\
      else\
         routine.parent_scope = routines[parent_name]\
      end\
   end\
   if not routine.parent_scope then\
      routine.parent_scope = routine.top_scope\
   end\
   if routine.parent_scope == routine then\
      routine.parent_scope = nil\
   end\
   recursion_check[routine] = true\
   routine.connect_checking = true\
   for _,line in ipairs(routine.lines) do\
      if line.type == \"call\" then\
         local target = routines[line.routine]\
         if not target then\
            compiler_error(routine.file, line.n,\
                           \"Cannot resolve routine %q\", line.routine)\
         elseif line.unsafe then\
            target.is_called_unsafely = true\
         else\
            routine.callees[line.routine] = target\
            target.callers[routine] = true\
            if line.is_jump then\
               recursion_check[routine] = nil\
               recursively_connect(entry_point, target, recursion_check)\
               recursion_check[routine] = true\
            else\
               recursively_connect(entry_point, target, recursion_check)\
            end\
         end\
      end\
   end\
   routine.connect_checking = nil\
   recursion_check[routine] = nil\
end\
\
local function recursively_make_callers_set(routine)\
   if routine.callers_set then return\
   else\
      routine.callers_set = bitset.new(total_number_of_scopes)\
      if routine.scope_number ~= nil then\
         routine.callers_set:set(routine.scope_number)\
      end\
      for caller in pairs(routine.callers) do\
         recursively_make_callers_set(caller)\
         routine.callers_set:union(caller.callers_set)\
      end\
   end\
end\
\
local function recursively_make_callees_set(routine)\
   if routine.callees_set then return\
   else\
      routine.callees_set = bitset.new(total_number_of_scopes)\
      if routine.scope_number ~= nil then\
         routine.callees_set:set(routine.scope_number)\
      end\
      for _,callee in pairs(routine.callees) do\
         recursively_make_callees_set(callee)\
         routine.callees_set:union(callee.callees_set)\
      end\
   end\
end\
\
local function recursively_make_exclusion_set(routine)\
   if routine.exclusion_set then return\
   else\
      recursively_make_callers_set(routine)\
      recursively_make_callees_set(routine)\
      routine.exclusion_set = bitset.new(total_number_of_scopes)\
      routine.exclusion_set:union(routine.callers_set)\
      routine.exclusion_set:union(routine.callees_set)\
      if next(routine.vars) ~= nil or next(routine.flags) ~= nil then\
         routine.scope_weight = routine.exclusion_set:popcount()\
      end\
   end\
end\
\
local function recursively_set_bank_and_slot(routine)\
   if routine.bank then return end\
   if routine.group then\
      if not groups[routine.group] then\
         compiler_error(routine.file, routine.line,\
                        \"no such group\")\
         routine.bank = \"FAKE\"\
         routine.slot = routine\
      else\
         routine.bank = groups[routine.group].bank\
         routine.slot = groups[routine.group].slot\
      end\
   else\
      if routine.parent_routine then\
         recursively_set_bank_and_slot(routine.parent_routine)\
         routine.bank = routine.parent_routine.bank\
         routine.slot = routine.parent_routine.slot\
      elseif bankcount > 1 then\
         compiler_error(routine.file, routine.line,\
                        \"ENTRY routines in multibank cartridges must have a GROUP tag\")\
         routine.bank = \"FAKE\"\
         routine.slot = routine\
      else\
         routine.bank = 0\
         routine.slot = 0\
      end\
   end\
end\
\
local function accumulate_longcalls(routine)\
   recursively_set_bank_and_slot(routine)\
   for name, target in pairs(routine.callees) do\
      recursively_set_bank_and_slot(target)\
      if target.slot == routine.slot and target.bank ~= routine.bank then\
         local longcall_name = routine.top_scope.name .. \"::glue_longcall\"\
            .. routine.slot\
         if not routines[longcall_name] then\
            compiler_error(nil, nil, \"Missing necessary glue routine: %q\",\
                           longcall_name)\
            routines[longcall_name] = {bank=-1,slot=-1,callers={},callees={}}\
         else\
            routines[longcall_name].callers[routine] = true\
            routine.callees[longcall_name] = routines[longcall_name]\
            if routines[longcall_name].top_scope == nil then\
               routines[longcall_name].top_scope = routine.top_scope\
               if next(routines[longcall_name].vars) ~= nil\
               or next(routines[longcall_name].flags) ~= nil then\
                  routines[longcall_name].scope_number = total_number_of_scopes\
                  routine.top_scope.number_of_scopes\
                     = routine.top_scope.number_of_scopes + 1\
                  total_number_of_scopes = total_number_of_scopes + 1\
               end\
            elseif routines[longcall_name].top_scope ~= routine.top_scope then\
               compiler_error(routines[longcall_name].file,\
                              routines[longcall_name].line,\
                              \"entry point confusion! Did you explicitly call this glue routine? Don't do that.\")\
            end\
         end\
      end\
   end\
end\
\
function do_connect_pass()\
   local recursion_check = {}\
   -- - assign each routine exactly one top scope, and an ID in that scope\
   -- - ensure that recursion does not happen\
   for _, entry_point in ipairs(entry_points) do\
      entry_point.number_of_scopes = 0\
      recursively_connect(entry_point, entry_point, recursion_check)\
      assert(next(recursion_check) == nil, \"recursion_check not clean!\")\
   end\
   -- - determine which longcall routines are required\
   for _, routine in pairs(routines) do\
      accumulate_longcalls(routine)\
   end\
   -- - quickly eliminate dead routines\
   for name, routine in pairs(routines) do\
      if routine.top_scope == nil then\
         if routine.is_called_unsafely then\
            compiler_error(routine.file, routine.first_line,\
                           \"Routine %q is called only UNSAFEly.\", name)\
         else\
            if should_print_dead_routines and routine.name then\
               print(\"Warning: \"..routine.file..\":\"..routine.start_line..\":\"\
                        ..routine.name..\" is a dead routine\")\
            end\
            routines[name] = nil\
         end\
      end\
   end\
   -- - calculate each routine's exclusion set\
   for name, routine in pairs(routines) do\
      recursively_make_exclusion_set(routine)\
   end\
   -- - print a pretty call graph\
   if should_print_call_graph then\
      -- TODO: make this better\
      for name,routine in pairs(routines) do\
         print(name)\
         if next(routine.callers) ~= nil then\
            for caller in pairs(routine.callers) do\
               print(\" \\\\\" .. caller.name)\
            end\
         else\
            print(\" (no callers)\")\
         end\
      end\
   end\
   -- - print the exclusion sets\
   if should_print_exclusion_sets then\
      for name,routine in pairs(routines) do\
         io.write(name,\"\\t\")\
         routine.exclusion_set:write(io.stdout)\
         io.write(\" \")\
         routine.callers_set:write(io.stdout)\
         io.write(\" \")\
         routine.callees_set:write(io.stdout)\
         io.write(\"\\n\")\
      end\
   end\
end\
","@src/connect_pass.lua")()
load("globals(\"do_assign_pass\")\
\
local assignments = {}\
local flag_assignments = {}\
\
local function varcompare(a,b)\
   if a.overhead ~= b.overhead then\
      return a.overhead > b.overhead\
   else\
      return a.name < b.name\
   end\
end\
\
local function sort_by_scope_weight(a,b)\
   if a.routine and b.routine then\
      if a.routine.scope_weight ~= b.routine.scope_weight then\
         return a.routine.scope_weight > b.routine.scope_weight\
      elseif a.routine.name ~= b.routine.name then\
         return a.routine.name < b.routine.name\
      end\
   elseif a.routine == nil and b.routine ~= nil then\
      return true\
   elseif a.routine ~= nil and b.routine == nil then\
      return false\
   end\
   return varcompare(a, b)\
end\
\
local function make_varlists(varmap, bigtable, routine)\
   local hardloc, softloc, anyloc = bigtable.hard, bigtable.soft, bigtable.any\
   for k,v in pairs(varmap) do\
      if v.location == \"ANY\" then\
         anyloc[#anyloc+1] = v\
      elseif type(v.location) == \"number\" then\
         hardloc[#hardloc+1] = v\
      else\
         softloc[#softloc+1] = v\
      end\
   end\
end\
\
local function try_assign_flag_to_location(flag, loc)\
   if flag_assignments[loc] then\
      if flag.persist then\
         -- persistent flags need their own slots, and this one already\
         -- has another flag in it\
         return false\
      elseif flag_assignments[loc].persist then\
         -- this slot already has a persistent flag in it\
         return false\
      elseif flag.routine.exclusion_set:any_bits_in_common(flag_assignments[loc].exclude) then\
         -- this slot has a flag in our exclusion set\
         return false\
      end\
   end\
   flag_assignments[loc] = flag_assignments[loc] or {}\
   table.insert(flag_assignments[loc], flag)\
   if flag.persist then flag_assignments[loc].persist = true\
   else\
      assert(flag.routine)\
      assert(flag.routine.scope_number)\
      if flag_assignments[loc].exclude == nil then\
         flag_assignments[loc].exclude = bitset.new(total_number_of_scopes)\
      end\
      flag_assignments[loc].exclude:set(flag.routine.scope_number)\
   end\
   flag.var = \"::flag\"..((loc-1)//8+1)\
   flag.bit = (loc-1)%8\
   return true\
end\
\
local function assign_flag(flag)\
   for n=1,#flag_assignments+1 do\
      if try_assign_flag_to_location(flag, n) then return end\
   end\
   error(\"NOTREACHED\")\
end\
\
local function try_assign_into_region(var, region)\
   for loc=region.start, region.endut - var.overhead do\
      if try_assign_to_location(var, loc) then return true end\
   end\
end\
\
local function try_assign_to_location(var, loc)\
   for byte=0, var.size-1 do\
      local addr = loc + (byte//var.block)*var.stride + byte\
      if assignments[addr] then\
         if var.persist then\
            -- persistent variables need their own slots, and this one already\
            -- has another variable in it\
            return false\
         elseif assignments[addr].persist then\
            -- this slot already has a persistent variable in it\
            return false\
         elseif var.routine.exclusion_set:any_bits_in_common(assignments[addr].exclude)  then\
            -- this slot has a variable in our exclusion set\
            return false\
         end\
      end\
   end\
   for byte=0, var.size-1 do\
      local addr = loc + (byte//var.block)*var.stride + byte\
      assignments[addr] = assignments[addr] or {}\
      table.insert(assignments[addr], var)\
      if var.persist then assignments[addr].persist = true\
      else\
         assert(var.routine)\
         assert(var.routine.scope_number)\
         if assignments[addr].exclude == nil then\
            assignments[addr].exclude = bitset.new(total_number_of_scopes)\
         end\
         assignments[addr].exclude:set(var.routine.scope_number)\
      end\
   end\
   var.location = loc\
   return true\
end\
\
local function try_assign_into_region(var, region)\
   for loc=region.start, region.endut - var.overhead do\
      if try_assign_to_location(var, loc) then return true end\
   end\
end\
\
local function try_assign_into_any_region(var)\
   for _,region in ipairs(memory_regions) do\
      if try_assign_into_region(var, region) then return true end\
   end\
end\
\
function do_assign_pass()\
   -- first let's sort out the flags!\
   local big_table_of_flags = {}\
   for name,flag in pairs(program_global_flags) do\
      big_table_of_flags[#big_table_of_flags+1] = flag\
   end\
   for name, routine in pairs(routines) do\
      for name,flag in pairs(routine.flags) do\
         flag.routine = routine\
         big_table_of_flags[#big_table_of_flags+1] = flag\
      end\
   end\
   if #big_table_of_flags > 0\
      and (#memory_regions == 0 or memory_regions[1].start >= 0x100\
           or memory_regions[1].stop >= 0x100) then\
      compiler_error(nil, nil, \"Since you're using #flags, the \\\"lowest\\\" region must lie within zero page\")\
      return\
   end\
   table.sort(big_table_of_flags, sort_by_scope_weight)\
   for _,flag in ipairs(big_table_of_flags) do\
      assign_flag(flag)\
      -- (always succeeds; if we're out of first-region space, we'll error\
      -- below)\
   end\
   if #flag_assignments > 0 then\
      for n=1,(#flag_assignments-1)//8+1 do\
         program_globals[\"::flag\"..n] = {name=\"::flag\"..n,\
                                         file=\"(no file)\",line=0,\
                                         location=memory_regions[1].name,\
                                         size=1,block=1,stride=0,\
                                         overhead=1,persist=true}\
      end\
   end\
   -- now let's do the vars!\
   local big_table_of_vars = {hard={},soft={},any={}}\
   make_varlists(program_globals, big_table_of_vars)\
   for name, routine in pairs(routines) do\
      local t = make_varlists(routine.vars, big_table_of_vars, routine)\
   end\
   table.sort(big_table_of_vars.hard, sort_by_scope_weight)\
   table.sort(big_table_of_vars.soft, sort_by_scope_weight)\
   table.sort(big_table_of_vars.any, sort_by_scope_weight)\
   -- first, try to fit all the hardcoded variables in their respective\
   -- locations\
   for _,var in ipairs(big_table_of_vars.hard) do\
      if not try_assign_to_location(var, var.location) then\
         compiler_error(var.file, var.line,\
                        \"No room at given address\")\
      end\
   end\
   if num_errors ~= 0 then return end\
   -- so far so good, now try the ones that care which region they go into\
   for _,var in ipairs(big_table_of_vars.soft) do\
      local region = memory_regions[var.location]\
      if not region then\
         compiler_error(var.file, var.line,\
                        \"unknown memory region: %q\", var.location)\
      elseif not try_assign_into_region(var, region) then\
         compiler_error(var.file, var.line,\
                        \"No room in given region\")\
      end\
   end\
   -- plow onwards!\
   for _,var in ipairs(big_table_of_vars.any) do\
      if not try_assign_into_any_region(var) then\
         compiler_error(var.file, var.line,\
                        \"No room in any region\")\
      end\
   end\
   if num_errors == 0 and should_print_variable_assignments then\
      local t = {}\
      for n, flag in pairs(big_table_of_flags) do\
         local var = program_globals[flag.var]\
         var.flat = var.flat or {}\
         table.insert(var.flat, flag.bit .. \"=\" .. flag.name)\
      end\
      for addr, assign in pairs(assignments) do\
         local subt = {}\
         for n=1,#assign do\
            if assign[n].flat then\
               assign[n].name = assign[n].name .. \" (\" .. table.concat(assign[n].flat, \", \") .. \")\"\
               assign[n].flat = nil\
            end\
            subt[#subt+1] = assign[n].name\
         end\
         table.sort(subt)\
         t[#t+1] = (\"$%04X %s\"):format(addr, table.concat(subt,\", \"))\
      end\
      table.sort(t)\
      -- ready for some black magic?\
      local n = 2\
      while n < #t-2 do\
         local start = t[n-1]:sub(7)\
         if t[n]:sub(7) == start and t[n+1]:sub(7) == start and\
            t[n+2]:sub(7) == start then\
            t[n] = \"      ...\"\
            repeat\
               table.remove(t, n+1)\
            until not t[n+2] or t[n+2]:sub(7) ~= start\
         end\
         n = n + 1\
      end\
      for n=1,#t do\
         print(t[n])\
      end\
   end\
end\
","@src/assign_pass.lua")()
load("local lpeg = require \"lpeg\"\
globals(\"do_generate_pass\")\
local function generate_longcall(f, routine_name, slot, bank, entry, type,\
                                 file, line)\
   local longcall_name = entry.name .. \"::glue_longcall\"..slot\
   assert(routines[longcall_name],\
          \"INTERNAL ERROR: this should have been handled in connect_pass\")\
   print(file, line)\
   local glue = routines[longcall_name]\
   if not glue.vars.target or not glue.vars.target.param then\
      compiler_error(file, line, \"Glue routine %q missing target param\",\
                     longcall_name)\
   end\
   if not glue.vars.target_bank or not glue.vars.target_bank.param then\
      compiler_error(file, line,\
                     \"Glue routine %q missing target_bank param\",\
                     longcall_name)\
   end\
   if glue.vars.target and glue.vars.target_bank then\
      f:write(\"\\tLDA #<\",routine_name,\"\\n\\tSTA \",glue.vars.target.location,\
              \"\\n\\tLDA #>\",routine_name,\"\\n\\tSTA \",glue.vars.target.location\
              ,\"+1\\n\\tLDA #\",bank,\"\\n\\tSTA \",glue.vars.target_bank.location,\
              \"\\n\",type,\" \",longcall_name,\"\\n\")\
   end\
end\
\
function do_generate_pass()\
   for name, routine in pairs(routines) do\
      active_routine = routine\
      local outpath = outdir .. DIRSEP .. \"hubris_\" .. name:gsub(\":\",\"-\") .. \".65c\"\
      make_directories_leading_up_to(outpath)\
      local f = assert(io.open(outpath, \"wb\"))\
      f:write(\".INCLUDE \\\"\",outdir,DIRSEP,[[memorymap\"\
.MACRO WAI\
.DB $CB\
.ENDM\
.MACRO STP\
.DB $DB\
.ENDM\
]])\
      f:write(\".BANK \",routine.bank,\" SLOT \",routine.slot,\"\\n\")\
      if routine.orga then\
         f:write(\".ORGA \",routine.orga,\"\\n.SECTION \\\"hubris_\",\
                 name, \"\\\" FORCE\\n\")\
      else\
         f:write([[\
.ORG 0\
.SECTION \"hubris_]], name, \"\\\" FREE\\n\")\
      end\
      for _,line in ipairs(routine.lines) do\
         if line.type == \"line\" then\
            local mangled = lpeg.match(identifier_mangler, line.l)\
            if imangle_errors ~= nil then\
               for _,id in ipairs(imangle_errors) do\
                  compiler_error(routine.file, line.n,\
                                 \"Unknown identifier: %q\", id)\
               end\
               imangle_errors = nil\
            else\
               f:write(mangled,\"\\n\")\
            end\
         elseif line.type == \"begin\" then\
            f:write(name,\":\\n\")\
            for n=1,#tracked_registers do\
               local reg = tracked_registers[n]\
               if routine.regs[reg.name] == \"PRESERVE\" then\
                  f:write(\"\\t\", reg.push, \"\\n\")\
               end\
            end\
         elseif line.type == \"call\" then\
            local target = routines[line.routine]\
            assert(target, \"INTERNAL ERROR: This should have been caught in the connect pass\")\
            if line.inter then\
               if target.group == routine.group then\
                  compiler_error(routine.file, line.n,\
                                 \"Spurious INTER tag on non-intergroup call\")\
               end\
            else\
               if target.group ~= routine.group then\
                  compiler_error(routine.file, line.n,\
                                 \"Missing INTER tag on intergroup call\")\
               end\
            end\
            if line.is_jump then\
               for n=1,#tracked_registers do\
                  local reg = tracked_registers[n]\
                  if routine.regs[reg.name] == \"PRESERVE\" then\
                     f:write(\"\\t\",reg.pop,\"\\n\")\
                  end\
               end\
               if line.inter and routine.regs.A == \"PRESERVE\" then\
                  compiler_error(routine.file, line.n,\
                                 \"Routine is marked PRESERVE A, but may clobber A with a long tailcall\")\
               end\
               if target.slot == routine.slot\
               and target.bank ~= routine.bank then\
                  generate_longcall(f,\
                                    line.routine, routine.slot,\
                                    target.bank, routine.top_scope,\
                                    \"JMP\", routine.file, line.n)\
               else\
                  if should_clobber_accumulator_on_intercalls then\
                     f:write(\"\\tLDA #\",target.bank,\"\\n\")\
                  end\
                  f:write(\"\\tJMP \",line.routine,\"\\n\")\
               end\
            else\
               for n=1,#tracked_registers do\
                  local reg = tracked_registers[n]\
                  if line.regs[reg.name] == \"PRESERVE\" then\
                     if target.regs[reg.name] == \"CLOBBER\" then\
                        -- we need to save this register ourselves\
                        f:write(\"\\t\", reg.push, \"\\n\")\
                     end\
                  --[[elseif routine.regs[reg.name] == \"CLOBBER\" then\
                     -- we don't care WHAT this routine does\
                     else\
                        if target.regs[reg.name] == \"CLOBBER\" then\
                        compiler_error(routine.file, line.n, \"Routine %q clobbers %s. Mark this call with CLOBBER %s or PRESERVE %s.\", target.name, reg, reg, reg)\
                        end]]\
                  end\
               end\
               if target.slot == routine.slot\
               and target.bank ~= routine.bank then\
                  generate_longcall(f,\
                                    line.routine, routine.slot,\
                                    target.bank, routine.top_scope,\
                                    \"JSR\", routine.file, routine.line)\
               else\
                  if should_clobber_accumulator_on_intercalls then\
                     f:write(\"\\tLDA #\",target.bank,\"\\n\")\
                  end\
                  f:write(\"\\tJSR \",line.routine,\"\\n\")\
               end\
               for n=#tracked_registers,1,-1 do\
                  local reg = tracked_registers[n]\
                  if line.regs[reg.name] == \"PRESERVE\" then\
                     if target.regs[reg.name] == \"CLOBBER\" then\
                        f:write(\"\\t\", reg.pull, \"\\n\")\
                     end\
                     --[[elseif routine.regs[reg.name] == \"CLOBBER\" then\
                        -- we don't care WHAT this routine does\
                        --else\
                        --assert(num_errors > 0 or target.regs[reg.name] ~= \"CLOBBER\")]]\
                  end\
               end\
            end\
         elseif line.type == \"return\" then\
            for n=#tracked_registers,1,-1 do\
               local reg = tracked_registers[n]\
               if routine.regs[reg.name] == \"PRESERVE\" then\
                  f:write(\"\\t\", reg.pull, \"\\n\")\
               end\
            end\
            if line.interrupt then\
               f:write(\"\\tRTI\\n\")\
            else\
               f:write(\"\\tRTS\\n\")\
            end\
         elseif line.type == \"bfc\" then\
            local var,bit = resolve_flag(line.flag)\
            if not var then\
               compiler_error(routine.file, line.n, \"Unknown flag\")\
            else\
               f:write(\"\\tBBR\",bit,\" \",identifier_mangling_function(var),\", \",\
                       line.label,\"\\n\")\
            end\
         elseif line.type == \"bfs\" then\
            local var,bit = resolve_flag(line.flag)\
            if not var then\
               compiler_error(routine.file, line.n, \"Unknown flag\")\
            else\
               f:write(\"\\tBBS\",bit,\" \",identifier_mangling_function(var),\", \",\
                       line.label,\"\\n\")\
            end\
         elseif line.type == \"clearflag\" then\
            local var,bit = resolve_flag(line.flag)\
            if not var then\
               compiler_error(routine.file, line.n, \"Unknown flag\")\
            else\
               f:write(\"\\tRMB\",bit,\" \",identifier_mangling_function(var),\"\\n\")\
            end\
         elseif line.type == \"setflag\" then\
            local var,bit = resolve_flag(line.flag)\
            if not var then\
               compiler_error(routine.file, line.n, \"Unknown flag\")\
            else\
               f:write(\"\\tSMB\",bit,\" \",identifier_mangling_function(var),\"\\n\")\
            end\
         else\
            compiler_error(routine.file, line.n, \"INTERNAL ERROR: Unknown line type %q\", line.type)\
         end\
      end\
      f:write(\".ENDS\\n\")\
      f:close()\
      asm_files[#asm_files+1] = outpath\
      active_routine = nil\
   end\
end\
","@src/generate_pass.lua")()
load("globals(\"do_assemble_pass\")\
local object_files = {}\
function do_assemble_pass()\
   table.sort(asm_files)\
   for _,inpath in ipairs(asm_files) do\
      local outpath = outdir..DIRSEP..inpath..\".o\"\
      make_directories_leading_up_to(outpath)\
      local cmd = \"wla-65c02 -o \"..outpath..\" \"..inpath\
      -- print(cmd)\
      if not os.execute(cmd) then\
         compiler_error(inpath, nil, \"wla-65c02 errored out\")\
         return\
      else\
         object_files[#object_files+1] = outpath\
      end\
   end\
   if num_errors == 0 then\
      table.sort(object_files)\
      make_directories_leading_up_to(outdir..DIRSEP..\"link\")\
      local f = assert(io.open(outdir..DIRSEP..\"link\",\"w\"))\
      f:write(\"[objects]\\n\")\
      for _,obj in ipairs(object_files) do\
         f:write(obj,\"\\n\")\
      end\
      f:close()\
   end\
end\
","@src/assemble_pass.lua")()
load("print_memory_usage(\"beginning\")\
\
do_eat_pass()\
print_memory_usage(\"eat\")\
maybe_error_exit()\
\
do_memorymap_pass()\
print_memory_usage(\"memorymap\")\
maybe_error_exit()\
\
do_connect_pass()\
print_memory_usage(\"connect\")\
maybe_error_exit()\
\
do_assign_pass()\
print_memory_usage(\"assign\")\
maybe_error_exit()\
\
do_generate_pass()\
print_memory_usage(\"generate\")\
maybe_error_exit()\
\
do_assemble_pass()\
print_memory_usage(\"assemble\")\
maybe_error_exit()\
","@src/main.lua")()
