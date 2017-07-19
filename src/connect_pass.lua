local lpeg = require "lpeg"

globals("do_connect_pass", "total_number_of_scopes")

total_number_of_scopes = 0

local function recursively_connect(entry_point, routine, recursion_check)
   if recursion_check[routine] then
      compiler_error(routine.file, routine.start_line,
                     "Routine %q recurses!", routine.name)
      return
   end
   if routine.connect_checking then
      -- following a safe recursion rabbit hole
      return
   end
   if routine.top_scope ~= nil and routine.top_scope ~= entry_point then
      compiler_error(routine.file, routine.start_line,
                     "Routine %q is called from multiple entry points!",
                     routine.name)
      return
   end
   if routine.top_scope == nil then
      if next(routine.vars) ~= nil or next(routine.flags) ~= nil then
         -- only create scopes for routines that actually have variables
         routine.scope_number = total_number_of_scopes
         entry_point.number_of_scopes = entry_point.number_of_scopes + 1
         total_number_of_scopes = total_number_of_scopes + 1
      end
      routine.top_scope = entry_point
   end
   local parent_name = lpeg.match(parent_routine_extractor, routine.name)
   if parent_name then
      if not routines[parent_name] then
         compiler_error(routine.file, routine.start_line,
                        "Parent routine %q does not exist", parent_name)
      else
         routine.is_subroutine = true
         routine.parent_scope = routines[parent_name]
      end
   end
   if not routine.parent_scope then
      routine.parent_scope = routine.top_scope
   end
   if routine.parent_scope == routine then
      routine.parent_scope = nil
   end
   recursion_check[routine] = true
   routine.connect_checking = true
   for _,line in ipairs(routine.lines) do
      if line.type == "call" then
         local target = routines[line.routine]
         if not target then
            compiler_error(routine.file, line.n,
                           "Cannot resolve routine %q", line.routine)
         elseif line.unsafe then
            target.is_called_unsafely = true
         else
            routine.callees[line.routine] = target
            target.callers[routine] = true
            if line.is_jump then
               recursion_check[routine] = nil
               recursively_connect(entry_point, target, recursion_check)
               recursion_check[routine] = true
            else
               recursively_connect(entry_point, target, recursion_check)
            end
         end
      end
   end
   routine.connect_checking = nil
   recursion_check[routine] = nil
end

local function recursively_make_callers_set(routine)
   if routine.callers_set then return
   else
      routine.callers_set = bitset.new(total_number_of_scopes)
      if routine.scope_number ~= nil then
         routine.callers_set:set(routine.scope_number)
      end
      for caller in pairs(routine.callers) do
         recursively_make_callers_set(caller)
         routine.callers_set:union(caller.callers_set)
      end
   end
end

local function recursively_make_callees_set(routine)
   if routine.callees_set then return
   else
      routine.callees_set = bitset.new(total_number_of_scopes)
      if routine.scope_number ~= nil then
         routine.callees_set:set(routine.scope_number)
      end
      for _,callee in pairs(routine.callees) do
         recursively_make_callees_set(callee)
         routine.callees_set:union(callee.callees_set)
      end
   end
end

local function recursively_make_exclusion_set(routine)
   if routine.exclusion_set then return
   else
      recursively_make_callers_set(routine)
      recursively_make_callees_set(routine)
      routine.exclusion_set = bitset.new(total_number_of_scopes)
      routine.exclusion_set:union(routine.callers_set)
      routine.exclusion_set:union(routine.callees_set)
      if next(routine.vars) ~= nil or next(routine.flags) ~= nil then
         routine.scope_weight = routine.exclusion_set:popcount()
      end
   end
end

local function recursively_set_bank_and_slot(routine)
   if routine.bank then return end
   if routine.group then
      if not groups[routine.group] then
         compiler_error(routine.file, routine.line,
                        "no such group")
         routine.bank = "FAKE"
         routine.slot = routine
      else
         routine.bank = groups[routine.group].bank
         routine.slot = groups[routine.group].slot
      end
   else
      if routine.is_subroutine then
         recursively_set_bank_and_slot(routine.parent_scope)
         routine.bank = routine.parent_scope.bank
         routine.slot = routine.parent_scope.slot
         routine.group = routine.parent_scope.group
      elseif bankcount > 1 then
         compiler_error(routine.file, routine.line,
                        "ENTRY routines in multibank cartridges must have a GROUP tag")
         routine.bank = "FAKE"
         routine.slot = routine
      else
         routine.bank = 0
         routine.slot = 0
      end
   end
end

local function accumulate_longcalls(routine)
   recursively_set_bank_and_slot(routine)
   for name, target in pairs(routine.callees) do
      recursively_set_bank_and_slot(target)
      if target.slot == routine.slot and target.bank ~= routine.bank then
         local longcall_name = routine.top_scope.name .. "::glue_longcall"
            .. routine.slot
         if not routines[longcall_name] then
            compiler_error(nil, nil, "Missing necessary glue routine: %q",
                           longcall_name)
            routines[longcall_name] = {bank=-1,slot=-1,callers={},callees={}}
         else
            routines[longcall_name].callers[routine] = true
            routine.callees[longcall_name] = routines[longcall_name]
            if routines[longcall_name].top_scope == nil then
               routines[longcall_name].top_scope = routine.top_scope
               if next(routines[longcall_name].vars) ~= nil
               or next(routines[longcall_name].flags) ~= nil then
                  routines[longcall_name].scope_number = total_number_of_scopes
                  routine.top_scope.number_of_scopes
                     = routine.top_scope.number_of_scopes + 1
                  total_number_of_scopes = total_number_of_scopes + 1
               end
            elseif routines[longcall_name].top_scope ~= routine.top_scope then
               compiler_error(routines[longcall_name].file,
                              routines[longcall_name].line,
                              "entry point confusion! Did you explicitly call this glue routine? Don't do that.")
            end
         end
      end
   end
end

function do_connect_pass()
   local recursion_check = {}
   -- - assign each routine exactly one top scope, and an ID in that scope
   -- - ensure that recursion does not happen
   for _, entry_point in ipairs(entry_points) do
      entry_point.number_of_scopes = 0
      recursively_connect(entry_point, entry_point, recursion_check)
      assert(next(recursion_check) == nil, "recursion_check not clean!")
   end
   -- - quickly eliminate dead routines (except longcalls)
   for name, routine in pairs(routines) do
      if routine.top_scope == nil and not name:match("::glue_longcall[0-7]$")
      then
         if routine.is_called_unsafely then
            compiler_error(routine.file, routine.first_line,
                           "Routine %q is called only UNSAFEly.", name)
         else
            if should_print_dead_routines and routine.name then
               print("Warning: "..routine.file..":"..routine.start_line..":"
                        ..routine.name.." is a dead routine")
            end
            routines[name] = nil
         end
      end
   end
   -- - determine which longcall routines are required
   for _, routine in pairs(routines) do
      accumulate_longcalls(routine)
   end
   -- - quickly eliminate dead routines again (including longcalls)
   for name, routine in pairs(routines) do
      if routine.top_scope == nil then
         if routine.is_called_unsafely then
            compiler_error(routine.file, routine.first_line,
                           "Routine %q is called only UNSAFEly.", name)
         else
            if should_print_dead_routines and routine.name then
               print("Warning: "..routine.file..":"..routine.start_line..":"
                        ..routine.name.." is a dead routine")
            end
            routines[name] = nil
         end
      end
   end
   -- - calculate each routine's exclusion set
   for name, routine in pairs(routines) do
      recursively_make_exclusion_set(routine)
   end
   -- - print a pretty call graph
   if should_print_call_graph then
      -- TODO: make this better
      for name,routine in pairs(routines) do
         print(name)
         if next(routine.callers) ~= nil then
            for caller in pairs(routine.callers) do
               print(" \\" .. caller.name)
            end
         else
            print(" (no callers)")
         end
      end
   end
   -- - print the exclusion sets
   if should_print_exclusion_sets then
      for name,routine in pairs(routines) do
         io.write(name,"\t")
         routine.exclusion_set:write(io.stdout)
         io.write(" ")
         routine.callers_set:write(io.stdout)
         io.write(" ")
         routine.callees_set:write(io.stdout)
         io.write("\n")
      end
   end
end
