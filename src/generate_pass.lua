local lpeg = require "lpeg"
globals("do_generate_pass")
local function generate_longcall(f, routine_name, slot, bank, entry, type,
                                 file, line)
   local longcall_name = entry.name .. "::glue_longcall"..slot
   assert(routines[longcall_name],
          "INTERNAL ERROR: this should have been handled in connect_pass")
   local glue = routines[longcall_name]
   if not glue.vars.target or not glue.vars.target.param then
      compiler_error(file, line, "Glue routine %q missing target param",
                     longcall_name)
   end
   if not glue.vars.target_bank or not glue.vars.target_bank.param then
      compiler_error(file, line,
                     "Glue routine %q missing target_bank param",
                     longcall_name)
   end
   if glue.vars.target and glue.vars.target_bank then
      f:write("\tLDA #<",routine_name,"\n\tSTA ",glue.vars.target.location,
              "\n\tLDA #>",routine_name,"\n\tSTA ",glue.vars.target.location
              ,"+1\n\tLDA #",bank,"\n\tSTA ",glue.vars.target_bank.location,
              "\n",type," ",longcall_name,"\n")
   end
end

function do_generate_pass()
   for name, routine in pairs(routines) do
      active_routine = routine
      local outpath = outdir .. DIRSEP .. "hubris_" .. name:gsub(":","-") .. ".65c"
      make_directories_leading_up_to(outpath)
      local f = assert(io.open(outpath, "wb"))
      f:write(".INCLUDE \"",outdir,DIRSEP,"common\"\n\n.BANK ",routine.bank," SLOT ",routine.slot,"\n")
      if routine.orga then
         f:write(".ORGA ",routine.orga,"\n.SECTION \"hubris_",
                 name, "\" FORCE\n")
      else
         f:write([[
.ORG 0
.SECTION "hubris_]], name, "\" FREE\n")
      end
      for _,line in ipairs(routine.lines) do
         if line.type == "line" then
            local mangled = lpeg.match(identifier_mangler, line.l)
            if imangle_errors ~= nil then
               for _,id in ipairs(imangle_errors) do
                  compiler_error(routine.file, line.n,
                                 "Unknown identifier: %q", id)
               end
               imangle_errors = nil
            else
               f:write(mangled,"\n")
            end
         elseif line.type == "begin" then
            f:write(name,":\n")
            for n=1,#tracked_registers do
               local reg = tracked_registers[n]
               if routine.regs[reg.name] == "PRESERVE" then
                  f:write("\t", reg.push, "\n")
               end
            end
         elseif line.type == "call" then
            local target = routines[line.routine]
            assert(target, "INTERNAL ERROR: This should have been caught in the connect pass")
            if line.inter then
               if target.group == routine.group then
                  compiler_error(routine.file, line.n,
                                 "Spurious INTER tag on non-intergroup call")
               end
            else
               if target.group ~= routine.group then
                  compiler_error(routine.file, line.n,
                                 "Missing INTER tag on intergroup call")
               end
            end
            if line.is_jump then
               for n=1,#tracked_registers do
                  local reg = tracked_registers[n]
                  if routine.regs[reg.name] == "PRESERVE" then
                     f:write("\t",reg.pop,"\n")
                  end
               end
               if line.inter and routine.regs.A == "PRESERVE" then
                  compiler_error(routine.file, line.n,
                                 "Routine is marked PRESERVE A, but may clobber A with a long tailcall")
               end
               if target.slot == routine.slot
               and target.bank ~= routine.bank then
                  generate_longcall(f,
                                    line.routine, routine.slot,
                                    target.bank, routine.top_scope,
                                    "JMP", routine.file, line.n)
               else
                  if should_clobber_accumulator_on_intercalls then
                     f:write("\tLDA #",target.bank,"\n")
                  end
                  f:write("\tJMP ",line.routine,"\n")
               end
            else
               for n=1,#tracked_registers do
                  local reg = tracked_registers[n]
                  if line.regs[reg.name] == "PRESERVE" then
                     if target.regs[reg.name] == "CLOBBER" then
                        -- we need to save this register ourselves
                        f:write("\t", reg.push, "\n")
                     end
                  --[[elseif routine.regs[reg.name] == "CLOBBER" then
                     -- we don't care WHAT this routine does
                     else
                        if target.regs[reg.name] == "CLOBBER" then
                        compiler_error(routine.file, line.n, "Routine %q clobbers %s. Mark this call with CLOBBER %s or PRESERVE %s.", target.name, reg, reg, reg)
                        end]]
                  end
               end
               if target.slot == routine.slot
               and target.bank ~= routine.bank then
                  generate_longcall(f,
                                    line.routine, routine.slot,
                                    target.bank, routine.top_scope,
                                    "JSR", routine.file, routine.line)
               else
                  if should_clobber_accumulator_on_intercalls then
                     f:write("\tLDA #",target.bank,"\n")
                  end
                  f:write("\tJSR ",line.routine,"\n")
               end
               for n=#tracked_registers,1,-1 do
                  local reg = tracked_registers[n]
                  if line.regs[reg.name] == "PRESERVE" then
                     if target.regs[reg.name] == "CLOBBER" then
                        f:write("\t", reg.pull, "\n")
                     end
                     --[[elseif routine.regs[reg.name] == "CLOBBER" then
                        -- we don't care WHAT this routine does
                        --else
                        --assert(num_errors > 0 or target.regs[reg.name] ~= "CLOBBER")]]
                  end
               end
            end
         elseif line.type == "return" then
            for n=#tracked_registers,1,-1 do
               local reg = tracked_registers[n]
               if routine.regs[reg.name] == "PRESERVE" then
                  f:write("\t", reg.pull, "\n")
               end
            end
            if line.interrupt then
               f:write("\tRTI\n")
            else
               f:write("\tRTS\n")
            end
         elseif line.type == "bfc" then
            local var,bit = resolve_flag(line.flag)
            if not var then
               compiler_error(routine.file, line.n, "Unknown flag: %s", line.flag)
            else
               f:write("\tBBR",bit," ",identifier_mangling_function(var),", ",
                       line.label,"\n")
            end
         elseif line.type == "bfs" then
            local var,bit = resolve_flag(line.flag)
            if not var then
               compiler_error(routine.file, line.n, "Unknown flag: %s", line.flag)
            else
               f:write("\tBBS",bit," ",identifier_mangling_function(var),", ",
                       line.label,"\n")
            end
         elseif line.type == "clearflag" then
            local var,bit = resolve_flag(line.flag)
            if not var then
               compiler_error(routine.file, line.n, "Unknown flag: %s", line.flag)
            else
               f:write("\tRMB",bit," ",identifier_mangling_function(var),"\n")
            end
         elseif line.type == "setflag" then
            local var,bit = resolve_flag(line.flag)
            if not var then
               compiler_error(routine.file, line.n, "Unknown flag: %s", line.flag)
            else
               f:write("\tSMB",bit," ",identifier_mangling_function(var),"\n")
            end
         else
            compiler_error(routine.file, line.n, "INTERNAL ERROR: Unknown line type %q", line.type)
         end
      end
      f:write(".ENDS\n")
      f:close()
      asm_files[#asm_files+1] = outpath
      active_routine = nil
   end
end
