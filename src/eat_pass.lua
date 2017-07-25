globals("asm_files", "routines", "entry_points", "tracked_registers",
        "memory_regions", "do_eat_pass", "program_global_flags",
        "slot_aliases", "groups", "bs", "bankcount")

local lpeg = require "lpeg"
local current_file, current_line, current_top_file
local function eat_error(...)
   return compiler_error(current_file, current_line, ...)
end

asm_files = {}
routines = {}
entry_points = {}
tracked_registers = {
   A={name="A",push="PHA",pull="PLA"},
   X={name="X",push="PHX",pull="PLX"},
   Y={name="Y",push="PHY",pull="PLY"},
}
tracked_registers[1] = tracked_registers.A
tracked_registers[2] = tracked_registers.X
tracked_registers[3] = tracked_registers.Y
program_globals = {}
program_global_flags = {}
slot_aliases = {}
groups = {}
memory_regions = {}
local current_routine
local stop_parsing_file
local add_lines_from

local function variable(dest_table, vardata, params)
   vardata.file = current_file
   vardata.line = current_line
   if #params < 3 then
      eat_error("Not enough parameters for variable directive (#... size name location)")
      return
   end
   vardata.location = table.remove(params, 1)
   if not lpeg.match(identifier_matcher, vardata.location) then
      vardata.location = lpeg.match(value_extractor, vardata.location)
      if not vardata.location then
         eat_error("Location value is invalid")
         return
      end
   end
   vardata.count, vardata.block, vardata.stride = lpeg.match(varsize_matcher, table.remove(params, 1))
   if not vardata.count then
      eat_error("Size value is invalid")
      return
   end
   vardata.size = vardata.count * vardata.block
   vardata.overhead = (vardata.size + vardata.block - 1) // vardata.block
      * vardata.stride + vardata.size
   vardata.name = table.remove(params, 1)
   if not lpeg.match(identifier_matcher * -1, vardata.name) then
      eat_error("Variable name is not a valid identifier")
      return
   end
   if dest_table[vardata.name] then
      eat_error("Duplicate variable definition for %q", vardata.name)
      return
   end
   while #params > 0 do
      local next_param = table.remove(params, 1)
      if next_param == "PERSIST" then
         if vardata.persist then
            eat_error("Redundant PERSIST tag")
         end
         vardata.persist = true
      else
         eat_error("unhandled variable tag: %s", next_param)
      end
   end
   dest_table[vardata.name] = vardata
end

local function flag(dest_table, flagdata, params)
   flagdata.file = current_file
   flagdata.line = current_line
   if #params < 1 then
      eat_error("Not enough parameters for flag directive (#... name)")
      return
   end
   flagdata.name = table.remove(params, 1)
   if not lpeg.match(identifier_matcher * -1, flagdata.name) then
      eat_error("Flag name is not a valid identifier")
      return
   end
   if dest_table[flagdata.name] then
      eat_error("Duplicate flag definition for %q", flagdata.name)
      return
   end
   while #params > 0 do
      local next_param = table.remove(params, 1)
      if next_param == "PERSIST" then
         if flagdata.persist then
            eat_error("Redundant PERSIST tag")
         end
         flagdata.persist = true
      else
         eat_error("unhandled flag tag: %s", next_param)
      end
   end
   dest_table[flagdata.name] = flagdata
end

local directives = {}
function directives.alias(params)
   if #params ~= 2 then
      eat_error("#alias requires two parameters")
      return
   end
   if current_aliases[params[1]] then
      eat_error("duplicate #alias definition for %q", params[1])
   else
      current_aliases[params[1]] = params[2]
   end
end
function directives.unalias(params)
   if #params ~= 1 then
      eat_error("#unalias requires one parameter")
      return
   end
   if current_aliases[param[1]] then
      current_aliases[param[1]] = nil
   else
      eat_error("#unalias for nonexistent #alias %q", params[1])
   end
end
function directives.include(params)
   if #params ~= 1 then
      eat_error("#include requires exactly one parameter")
      return
   end
   local path = params[1]
   if DIRSEP ~= "/" then path = path:gsub("/", DIRSEP) end
   local f,found_path
   for n=1,#indirs do
      found_path = indirs[n]..DIRSEP..path
      f = io.open(found_path, "rb")
      if f then break end
   end
   if not f then
      eat_error("unable to locate file: %q", path)
      return
   end
   local old_current_file, old_current_line = current_file, current_line
   table.insert(include_stack, old_current_file..":"..old_current_line)
   current_file, current_line = found_path, 1
   add_lines_from(f)
   table.remove(include_stack)
   current_file, current_line = old_current_file, old_current_line
   f:close()
end
function directives.global(params)
   return variable(program_globals, {persist=true}, params)
end
directives["local"] = function(params)
   return variable(current_routine.vars, {routine=current_routine}, params)
end
function directives.sublocal(params)
   return variable(current_routine.vars, {routine=current_routine,sublocal=true}, params)
end
function directives.param(params)
   return variable(current_routine.vars, {routine=current_routine,param=true}, params)
end
function directives.globalflag(params)
   return flag(program_global_flags, {persist=true}, params)
end
function directives.localflag(params)
   return flag(current_routine.flags, {routine=current_routine}, params)
end
function directives.sublocalflag(params)
   return flag(current_routine.flags, {routine=current_routine,sublocal=true}, params)
end
function directives.paramflag(params)
   return flag(current_routine.flags, {routine=current_routine,param=true}, params)
end
function directives.bs(params)
   if #params ~= 1 then
      eat_error("#bs requires exactly one argument")
   elseif bs ~= nil then
      eat_error("multiple #bs directives cannot coexist")
   else
      bs = tonumber(params[1])
      if bs == nil or bs|0 ~= bs or bs < 0 or bs > 3 then
         eat_error("invalid #bs value, must be 0--3")
         bs = nil
      end
   end
end
function directives.bankcount(params)
   if #params ~= 1 then
      eat_error("#bankcount requires exactly one argument")
   elseif bankcount ~= nil then
      eat_error("multiple #bankcount directives cannot coexist")
   else
      bankcount = tonumber(params[1])
      if bankcount == nil or bankcount|0 ~= bankcount or bankcount < 1
      or (bankcount - 1) & bankcount ~= 0 then
         eat_error("invalid #bankcount value, must be a power of 2 >= 1")
         bankcount = nil
      end
   end
end
function directives.region(params)
   if #params ~= 3 then
      eat_error("#region needs 3 parameters")
      return
   end
   local start = lpeg.match(value_extractor, params[1])
   if not start then
      eat_error("invalid region first-param")
      return
   end
   local stop = lpeg.match(value_extractor, params[2])
   if not stop then
      eat_error("invalid region second-param")
      return
   end
   local name = params[3]
   if not lpeg.match(identifier_matcher, name) or name == "ANY" then
      eat_error("invalid region name")
      return
   end
   if stop < start then
      eat_error("region stops before it starts")
      return
   end
   local endut = stop+1
   for _,region in ipairs(memory_regions) do
      if start <= region.stop and region.start <= stop then
         eat_error("region overlaps with existing region %q", region.name)
      end
   end
   memory_regions[#memory_regions+1] = {start=start, stop=stop,
                                        endut=endut, name=name}
   memory_regions[name] = memory_regions[#memory_regions]
end
function directives.slot(params)
   if #params ~= 2 then
      eat_error("#slot needs two parameters: the slot number and the name of the slot")
   else
      local slotno = tonumber(params[1])
      if slotno|0 ~= slotno or slotno < 0 or slotno >= 8 then
         eat_error("absurd slot number")
         return
      end
      local slotname = params[2]
      if slot_aliases[slotname] then
         eat_error("multiple #slots named %q exist", slotname)
         return
      end
      slot_aliases[slotname] = slotno
   end
end
function directives.group(params)
   if #params ~= 3 then
      eat_error("#group needs three parameters: bank number, slot, and group name")
   else
      local bankno = tonumber(params[1])
      if bankno|0 ~= bankno or bankno >= 256 or bankno < 0 then
         eat_error("absurd bank number")
      elseif groups[params[3]] then
         eat_error("multiple #groups named %q exist", params[3])
      else
         groups[params[3]] = {bank=bankno, slot=params[2], name=params[3],
                             file=current_file, line=current_line}
      end
   end
end
function directives.routine(params)
   if current_routine ~= nil then
      eat_error("previous #routine did not #endroutine yet")
      stop_parsing_file = true
      return
   elseif #params < 1 then
      eat_error("#routine requires at least one parameter")
      stop_parsing_file = true
      return
   elseif not lpeg.match(routine_name_validator, params[1]) then
      eat_error("routine name is not valid; must be one or more identifiers (not beginning with _) separated by `::`")
      stop_parsing_file = true
      return
   elseif routines[params[1]] then
      eat_error("another #routine with the same name already exists")
      stop_parsing_file = true
      return
   end
   current_routine = {name=table.remove(params,1), lines={},
                      file=current_file, start_line=current_line, regs={},
                      callers={}, callees={}, vars={}, flags={},
                      indirectcallers={},
                      top_file=current_top_file}
   routines[current_routine.name] = current_routine
   local current_register_mode
   while #params > 0 do
      local next_param = table.remove(params, 1)
      if next_param == "ENTRY" then
         if current_routine.is_entry_point then
            eat_error("multiple ENTRY tags on the same #routine are meaningless")
         else
            current_routine.is_entry_point = true
            entry_points[#entry_points+1] = current_routine
         end
      elseif tracked_registers[next_param] then
         if current_register_mode == nil then
            eat_error("register names in #routine directive must be preceded by CLOBBER or PRESERVE")
         elseif current_routine.regs[next_param] ~= nil then
            eat_error("register names cannot occur more than once in the same #routine directive")
         else
            current_routine.regs[next_param] = current_register_mode
         end
      elseif next_param == "CLOBBER" or next_param == "PRESERVE" then
         current_register_mode = next_param
      elseif next_param == "ORGA" then
         next_param = table.remove(params, 1)
         if next_param == nil then
            eat_error("ORGA is missing a parameter")
         else
            local loc = lpeg.match(value_extractor, next_param)
            if not loc then
               eat_error("ORGA has invalid location")
            end
            current_routine.orga = loc
         end
      elseif next_param == "GROUP" then
         next_param = table.remove(params, 1)
         if next_param == nil then
            eat_error("GROUP is missing a parameter")
         elseif current_routine.group then
            eat_error("multiple GROUP tags on the same #routine are meaningless")
         else
            current_routine.group = next_param
         end
      else
         eat_error("unhandled #routine tag: %s", next_param)
      end
   end
end
function directives.call(params)
   if #params < 1 then
      eat_error("#call requires a parameter")
      return
   end
   local pseudoline = {type="call", n=current_line,regs={},
                       routine=table.remove(params,1)}
   local current_register_mode
   while #params > 0 do
      local next_param = table.remove(params, 1)
      if tracked_registers[next_param] then
         if current_register_mode == nil then
            eat_error("register names in #call directive must be preceded by CLOBBER or PRESERVE")
         elseif pseudoline.regs[next_param] ~= nil then
            eat_error("register names cannot occur more than once in the same #call directive")
         else
            pseudoline.regs[next_param] = current_register_mode
         end
      elseif next_param == "CLOBBER" or next_param == "PRESERVE" then
         current_register_mode = next_param
      elseif next_param == "JUMP" then
         if pseudoline.is_jump then
            eat_error("redundant JUMP tag on #call")
         end
         pseudoline.is_jump = true
      elseif next_param == "UNSAFE" then
         if pseudoline.unsafe then
            eat_error("redundant UNSAFE tag on #call")
         end
         pseudoline.unsafe = true
      elseif next_param == "INTER" then
         if pseudoline.inter then
            eat_error("redundant INTER tag on #call")
         end
         pseudoline.inter = true
      else
         eat_error("unhandled #call tag: %s", next_param)
      end
   end
   current_routine.lines[#current_routine.lines+1] = pseudoline
end
function directives.indirectcallers(params)
   if #params < 1 then
      eat_error("#indirectcallers requires at least one parameter")
      return
   end
   while #params > 0 do
      local target = table.remove(params, 1)
      if current_routine.indirectcallers[target] then
         eat_error("Routine %q specified more than once in #indirectcallers directives", target)
      elseif target == current_routine.name then
         eat_error("Routine %q specified in its own #indirectcallers directive", target)
      else
         current_routine.indirectcallers[target] = current_line
      end
   end
end
directives.indirectcaller = directives.indirectcallers
function directives.branchflagset(params)
   if #params ~= 2 then
      eat_error("#branchflagset requires exactly two parameters")
      return
   end
   if not lpeg.match(good_label_matcher, params[2]) then
      eat_error("#branchflagset label was not valid")
      return
   end
   current_routine.lines[#current_routine.lines+1]
      = {type="bfs", n=current_line, flag=params[1], label=params[2]}
end
function directives.branchflagclear(params)
   if #params ~= 2 then
      eat_error("#branchflagclear requires exactly two parameters")
      return
   end
   if not lpeg.match(good_label_matcher, params[2]) then
      eat_error("#branchflagclear label was not valid")
      return
   end
   current_routine.lines[#current_routine.lines+1]
      = {type="bfc", n=current_line, flag=params[1], label=params[2]}
end
directives.branchflagreset = directives.branchflagclear
function directives.setflag(params)
   if #params ~= 1 then
      eat_error("#setflag requires exactly one parameter")
      return
   end
   current_routine.lines[#current_routine.lines+1]
      = {type="setflag", n=current_line, flag=params[1]}
end
function directives.clearflag(params)
   if #params ~= 1 then
      eat_error("#clearflag requires exactly one parameter")
      return
   end
   current_routine.lines[#current_routine.lines+1]
      = {type="clearflag", n=current_line, flag=params[1]}
end
directives.resetflag = directives.clearflag
function directives.begin(params)
   if #params ~= 0 then
      eat_error("#begin has no parameters")
   elseif current_routine.has_begun then
      eat_error("this routine has already had a #begin")
      return
   end
   current_routine.has_begun = true
   current_routine.lines[#current_routine.lines+1]
      = {type="begin",n=current_line}
end
directives["return"] = function(params)
   if #params ~= 0 and (#params ~= 1 or params[1] ~= "INTERRUPT") then
      eat_error("`#return` and `#return INTERRUPT` are the only valid #return directives")
   end
   -- multiple #returns are allowed
   current_routine.has_returned = true
   current_routine.lines[#current_routine.lines+1]
      = {type="return",n=current_line,interrupt=params[1] == "INTERRUPT"}
end
directives.endroutine = function(params)
   if #params ~= 0 and (#params ~= 1 or params[1] ~= "NORETURN") then
      eat_error("`#endroutine` and `#endroutine NORETURN` are the only valid #endroutine directives")
   end
   if not current_routine.has_begun then
      eat_error("#routine lacks a #begin")
   end
   if params[1] ~= "NORETURN" and not current_routine.has_returned then
      eat_error("#routine %s lacks a #return directive, and its #endroutine lacks a `NORETURN` tag", current_routine.name)
   end
   current_routine = nil
end
function add_lines_from(f)
   for l in f:lines() do
      l = lpeg.match(comment_stripper, l)
      if lpeg.match(directive_tester, l) then
         local directive, params = lpeg.match(directive_matcher, l)
         if not directive then
            eat_error("unparseable directive")
         elseif directives[directive] then
            directives[directive](params)
         else
            eat_error("unknown directive: #%s", directive)
         end
      elseif current_routine then
         current_routine.lines[#current_routine.lines+1]
            = {type="line",n=current_line,l=lpeg.match(aliaser,l)}
      elseif not lpeg.match(blank_line_tester, l) then
         eat_error("stray nonblank line")
      end
      current_line = current_line + 1
      if stop_parsing_file then break end
   end
end
local function eat_file(src)
   current_file = src
   current_top_file = src
   current_line = 1
   stop_parsing_file = false
   local f = assert(io.open(src, "rb"))
   current_aliases = {}
   add_lines_from(f)
   current_aliases = nil
   f:close()
end

function do_eat_pass()
   -- First step, gather up all the source files and process them one by one
   local function recursively_eat_directory(dir)
      for f in lfs.dir(dir) do
         if f:sub(1,1) == "." then
            -- ignore this file, it's either a special directory or otherwise
            -- hidden
         elseif f:sub(-3,-1) == ".hu" then
            -- it's a Hubris source file!
            eat_file(dir .. DIRSEP .. f)
         elseif f:sub(-4,-1) == ".65c" then
            -- it's a 65C02 source file!
            asm_files[#asm_files+1] = dir .. DIRSEP .. f
         elseif lfs.attributes(dir .. DIRSEP .. f, "mode") == "directory" then
            -- it's a subdirectory!
            recursively_eat_directory(dir .. DIRSEP .. f)
         else
            -- ignore this file, it's not something we know what to do with
         end
      end
   end
   for n=1,#indirs do
      recursively_eat_directory(indirs[n])
   end
   current_file, current_line = nil, nil
end
