globals("make_directories_leading_up_to")

local lfs = require "lfs"

local dirs_okay = {}
function make_directories_leading_up_to(path)
   -- this will behave a little strangely in some cases on Windows, in
   -- particular if the output directory is an absolute path on a drive letter
   -- that does not exist
   -- strip trailing DIRSEPs
   local n = #path
   while path:sub(n,n) == DIRSEP do
      n = n - 1
   end
   -- skip down to the next DIRSEP, if any
   while n > 0 and path:sub(n,n) ~= DIRSEP do
      n = n - 1
   end
   -- either "/" or "" is all that is left
   if n <= 1 then return end
   local dir = path:sub(1,n)
   -- is this already a directory?
   -- (save a system call maybe)
   if dirs_okay[dir] then return true end
   local st = lfs.attributes(dir, "mode")
   if st == "directory" then
      dirs_okay[dir] = true
   elseif st ~= nil then
      return -- let a future error handle this...
   else
      if not lfs.mkdir(dir) then
         make_directories_leading_up_to(dir)
         assert(lfs.mkdir(dir))
      end
      dirs_okay[dir] = true
   end
end
