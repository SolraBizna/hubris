globals("do_assemble_pass")
local object_files = {}
function do_assemble_pass()
   table.sort(asm_files)
   for _,inpath in ipairs(asm_files) do
      local outpath = outdir..DIRSEP..inpath..".o"
      make_directories_leading_up_to(outpath)
      local cmd = "wla-65c02 -o "..outpath.." "..inpath
      -- print(cmd)
      if not os.execute(cmd) then
         compiler_error(inpath, nil, "wla-65c02 errored out")
         return
      else
         object_files[#object_files+1] = outpath
      end
   end
   if num_errors == 0 then
      table.sort(object_files)
      make_directories_leading_up_to(outdir..DIRSEP.."link")
      local f = assert(io.open(outdir..DIRSEP.."link","w"))
      f:write("[objects]\n")
      for _,obj in ipairs(object_files) do
         f:write(obj,"\n")
      end
      f:close()
   end
end
