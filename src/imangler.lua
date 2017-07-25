local lpeg = require "lpeg"

globals("identifier_mangling_function","identifier_creating_function",
        "active_routine","program_globals","imangle_errors","resolve_flag")

function identifier_mangling_function(id)
   if current_aliases and current_aliases[id] then
      return identifier_mangling_function(current_aliases[id])
   end
   if active_routine then
      local proutine,var = lpeg.match(parent_routine_extractor, id)
      if proutine and active_routine.callees[proutine]
         and active_routine.callees[proutine].vars[var]
         and active_routine.callees[proutine].vars[var].param then
         return active_routine.callees[proutine].vars[var].location
      end
      if active_routine.vars[id] then
         return active_routine.vars[id].location
      end
      local scope = active_routine.parent_scope
      while scope do
         if scope.vars[id]
         and (scope.vars[id].param or scope.vars[id].sublocal) then
            return scope.vars[id].location
         end
         scope = scope.parent_scope
      end
   end
   if program_globals[id] then
      return program_globals[id].location
   end
   return id
   --[[
   if not imangle_errors then
      imangle_errors = {}
   end
   table.insert(imangle_errors, id)
   return "__INVALID__"
   ]]
end
function resolve_flag(id)
   if active_routine then
      local proutine,flag = lpeg.match(parent_routine_extractor, id)
      if proutine and active_routine.callees[proutine]
         and active_routine.callees[proutine].flags[flag]
         and active_routine.callees[proutine].flags[flag].param then
            return active_routine.callees[proutine].flags[flag].var,
            active_routine.callees[proutine].flags[flag].bit
      end
      if active_routine.flags[id] then
         return active_routine.flags[id].var, active_routine.flags[id].bit
      end
      local scope = active_routine.parent_scope
      while scope do
         if scope.flags[id]
         and (scope.flags[id].param or scope.flags[id].sublocal) then
            return scope.flags[id].var, scope.flags[id].bit
         end
         scope = scope.parent_scope
      end
   end
   if program_global_flags[id] then
      return program_global_flags[id].var, program_global_flags[id].bit
   end
end
function identifier_creating_function(id)
   -- not actually using this right now
   return id
end
