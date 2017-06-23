globals("do_assign_pass")

local assignments = {}
local flag_assignments = {}

local function varcompare(a,b)
   if a.overhead ~= b.overhead then
      return a.overhead > b.overhead
   else
      return a.name < b.name
   end
end

local function sort_by_scope_weight(a,b)
   if a.routine and b.routine then
      if a.routine.scope_weight ~= b.routine.scope_weight then
         return a.routine.scope_weight > b.routine.scope_weight
      elseif a.routine.name ~= b.routine.name then
         return a.routine.name < b.routine.name
      end
   elseif a.routine == nil and b.routine ~= nil then
      return true
   elseif a.routine ~= nil and b.routine == nil then
      return false
   end
   return varcompare(a, b)
end

local function make_varlists(varmap, bigtable, routine)
   local hardloc, softloc, anyloc = bigtable.hard, bigtable.soft, bigtable.any
   for k,v in pairs(varmap) do
      if v.location == "ANY" then
         anyloc[#anyloc+1] = v
      elseif type(v.location) == "number" then
         hardloc[#hardloc+1] = v
      else
         softloc[#softloc+1] = v
      end
   end
end

local function try_assign_flag_to_location(flag, loc)
   if flag_assignments[loc] then
      if flag.persist then
         -- persistent flags need their own slots, and this one already
         -- has another flag in it
         return false
      elseif flag_assignments[loc].persist then
         -- this slot already has a persistent flag in it
         return false
      elseif flag.routine.exclusion_set:any_bits_in_common(flag_assignments[loc].exclude) then
         -- this slot has a flag in our exclusion set
         return false
      end
   end
   flag_assignments[loc] = flag_assignments[loc] or {}
   table.insert(flag_assignments[loc], flag)
   if flag.persist then flag_assignments[loc].persist = true
   else
      assert(flag.routine)
      assert(flag.routine.scope_number)
      if flag_assignments[loc].exclude == nil then
         flag_assignments[loc].exclude = bitset.new(total_number_of_scopes)
      end
      flag_assignments[loc].exclude:set(flag.routine.scope_number)
   end
   flag.var = "::flag"..((loc-1)//8+1)
   flag.bit = (loc-1)%8
   return true
end

local function assign_flag(flag)
   for n=1,#flag_assignments+1 do
      if try_assign_flag_to_location(flag, n) then return end
   end
   error("NOTREACHED")
end

local function try_assign_into_region(var, region)
   for loc=region.start, region.endut - var.overhead do
      if try_assign_to_location(var, loc) then return true end
   end
end

local function try_assign_to_location(var, loc)
   for byte=0, var.size-1 do
      local addr = loc + (byte//var.block)*var.stride + byte
      if assignments[addr] then
         if var.persist then
            -- persistent variables need their own slots, and this one already
            -- has another variable in it
            return false
         elseif assignments[addr].persist then
            -- this slot already has a persistent variable in it
            return false
         elseif var.routine.exclusion_set:any_bits_in_common(assignments[addr].exclude)  then
            -- this slot has a variable in our exclusion set
            return false
         end
      end
   end
   for byte=0, var.size-1 do
      local addr = loc + (byte//var.block)*var.stride + byte
      assignments[addr] = assignments[addr] or {}
      table.insert(assignments[addr], var)
      if var.persist then assignments[addr].persist = true
      else
         assert(var.routine)
         assert(var.routine.scope_number)
         if assignments[addr].exclude == nil then
            assignments[addr].exclude = bitset.new(total_number_of_scopes)
         end
         assignments[addr].exclude:set(var.routine.scope_number)
      end
   end
   var.location = loc
   return true
end

local function try_assign_into_region(var, region)
   for loc=region.start, region.endut - var.overhead do
      if try_assign_to_location(var, loc) then return true end
   end
end

local function try_assign_into_any_region(var)
   for _,region in ipairs(memory_regions) do
      if try_assign_into_region(var, region) then return true end
   end
end

function do_assign_pass()
   -- first let's sort out the flags!
   local big_table_of_flags = {}
   for name,flag in pairs(program_global_flags) do
      big_table_of_flags[#big_table_of_flags+1] = flag
   end
   for name, routine in pairs(routines) do
      for name,flag in pairs(routine.flags) do
         flag.routine = routine
         big_table_of_flags[#big_table_of_flags+1] = flag
      end
   end
   if #big_table_of_flags > 0
      and (#memory_regions == 0 or memory_regions[1].start >= 0x100
           or memory_regions[1].stop >= 0x100) then
      compiler_error(nil, nil, "Since you're using #flags, the \"lowest\" region must lie within zero page")
      return
   end
   table.sort(big_table_of_flags, sort_by_scope_weight)
   for _,flag in ipairs(big_table_of_flags) do
      assign_flag(flag)
      -- (always succeeds; if we're out of first-region space, we'll error
      -- below)
   end
   if #flag_assignments > 0 then
      for n=1,(#flag_assignments-1)//8+1 do
         program_globals["::flag"..n] = {name="::flag"..n,
                                         file="(no file)",line=0,
                                         location=memory_regions[1].name,
                                         size=1,block=1,stride=0,
                                         overhead=1,persist=true}
      end
   end
   -- now let's do the vars!
   local big_table_of_vars = {hard={},soft={},any={}}
   make_varlists(program_globals, big_table_of_vars)
   for name, routine in pairs(routines) do
      local t = make_varlists(routine.vars, big_table_of_vars, routine)
   end
   table.sort(big_table_of_vars.hard, sort_by_scope_weight)
   table.sort(big_table_of_vars.soft, sort_by_scope_weight)
   table.sort(big_table_of_vars.any, sort_by_scope_weight)
   -- first, try to fit all the hardcoded variables in their respective
   -- locations
   for _,var in ipairs(big_table_of_vars.hard) do
      if not try_assign_to_location(var, var.location) then
         compiler_error(var.file, var.line,
                        "No room at given address")
      end
   end
   if num_errors ~= 0 then return end
   -- so far so good, now try the ones that care which region they go into
   for _,var in ipairs(big_table_of_vars.soft) do
      local region = memory_regions[var.location]
      if not region then
         compiler_error(var.file, var.line,
                        "unknown memory region: %q", var.location)
      elseif not try_assign_into_region(var, region) then
         compiler_error(var.file, var.line,
                        "No room in given region")
      end
   end
   -- plow onwards!
   for _,var in ipairs(big_table_of_vars.any) do
      if not try_assign_into_any_region(var) then
         compiler_error(var.file, var.line,
                        "No room in any region")
      end
   end
   if num_errors == 0 and should_print_variable_assignments then
      local t = {}
      for n, flag in pairs(big_table_of_flags) do
         local var = program_globals[flag.var]
         var.flat = var.flat or {}
         table.insert(var.flat, flag.bit .. "=" .. flag.name)
      end
      for addr, assign in pairs(assignments) do
         local subt = {}
         for n=1,#assign do
            if assign[n].flat then
               assign[n].name = assign[n].name .. " (" .. table.concat(assign[n].flat, ", ") .. ")"
               assign[n].flat = nil
            end
            subt[#subt+1] = assign[n].name
         end
         table.sort(subt)
         t[#t+1] = ("$%04X %s"):format(addr, table.concat(subt,", "))
      end
      table.sort(t)
      -- ready for some black magic?
      local n = 2
      while n < #t-2 do
         local start = t[n-1]:sub(7)
         if t[n]:sub(7) == start and t[n+1]:sub(7) == start and
            t[n+2]:sub(7) == start then
            t[n] = "      ..."
            repeat
               table.remove(t, n+1)
            until not t[n+2] or t[n+2]:sub(7) ~= start
         end
         n = n + 1
      end
      for n=1,#t do
         print(t[n])
      end
   end
end
