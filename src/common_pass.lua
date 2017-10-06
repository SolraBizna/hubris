globals("do_common_pass")
function do_common_pass()
   if bs == nil then
      compiler_error(nil, nil, "no #bs directive found")
      return
   end
   if bankcount == nil then
      compiler_error(nil, nil, "no #bankcount directive found")
      return
   end
   -- assign banks and slots
   for name, group in pairs(groups) do
      if group.bank >= bankcount then
         compiler_error(bank.file, bank.line,
                        "bank number too large")
      end
      group.slot = slot_aliases[group.slot] or group.slot
      if type(group.slot) == "string" then
         group.slot = tonumber(group.slot)
         if not group.slot then
            compiler_error(group.file, group.line,
                           "unknown slot alias")
         end
      end
      if group.slot then
         if group.slot|0 ~= group.slot or group.slot >= (1<<bs) then
            compiler_error(group.file, group.line,
                           "slot number out of range")
         end
      end
   end
   if num_errors == 0 then
      -- generate output/common
      make_directories_leading_up_to(outdir..DIRSEP.."common")
      local f = assert(io.open(outdir..DIRSEP.."common", "w"))
      local banksize = 32768 >> bs
      f:write("; Memory map\n.MEMORYMAP\nDEFAULTSLOT 0\n")
      for slot=0,(1<<bs)-1 do
         f:write(("SLOT %i $%04X $%04X\n"):format(slot,
                                                  32768+banksize*slot,
                                                  banksize))
      end
      f:write(".ENDME\n.ROMBANKSIZE ",("$%04X"):format(banksize),
              "\n.ROMBANKS ",bankcount,"\n; Group assignments\n");
      local t = {}
      for name, group in pairs(groups) do
         t[#t+1] = ".DEFINE hubris_Group_"..name.."_bank "..group.bank.."\n"
            ..".DEFINE hubris_Group_"..name.."_slot "..group.slot.."\n"
      end
      for name, value in pairs(slot_aliases) do
         t[#t+1] = ".DEFINE hubris_Slot_"..name.."_slot "..value.."\n"
      end
      table.sort(t)
      for n=1,#t do f:write(t[n]) end
      table.sort(memory_regions, function(a,b) return a.start < b.start end)
      table.sort(commons, function(a,b)
                    if a.file < b.file then
                       return true
                    elseif a.file > b.file then
                       return false
                    else
                       return a.start_line < b.start_line
                    end
      end)
      for i,v in ipairs(commons) do
         if #v.lines == 0 then
            print(v.file..":"..v.start_line..": WARNING: `#common` section is empty")
         else
            f:write("; ",v.file," common section on line ",v.start_line,"\n")
            for _,l in ipairs(v.lines) do
               f:write(l,"\n");
            end
         end
      end
      f:close()
   end
end
