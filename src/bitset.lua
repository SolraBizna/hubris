local bitset = {}
local INT_BITS = 1
while 1 << INT_BITS ~= 0 do INT_BITS = INT_BITS << 1 end
assert(INT_BITS & (INT_BITS - 1) == 0, "non power of two INT_BITS")
local INT_SHIFT = 0
while 1 << INT_SHIFT ~= INT_BITS do INT_SHIFT = INT_SHIFT + 1 end
local INT_MASK = INT_BITS - 1

bitset._mt = {__index={}}
function bitset._mt.__index:set(n)
   local int = (n >> INT_SHIFT) + 1
   local bit = 1 << (n & INT_MASK)
   self[int] = self[int] | bit
end
function bitset._mt.__index:unset(n)
   local int = (n >> INT_SHIFT) + 1
   local bit = 1 << (n & INT_MASK)
   self[int] = self[int] & ~bit
end
function bitset._mt.__index:get(n)
   local int = (n >> INT_SHIFT) + 1
   local bit = 1 << (n & INT_MASK)
   return self[int] & bit ~= 0
end
function bitset._mt.__index:union(other)
   assert(other.count == self.count, "union requires both sets to have the same count")
   for n=1,self.intcount do
      self[n] = self[n] | other[n]
   end
end
function bitset._mt.__index:popcount()
   -- "sparse ones" algorithm
   local pop = 0
   for n=1,self.intcount do
      local m = self[n]
      while m ~= 0 do
         m = m & (m - 1)
         pop = pop + 1
      end
   end
   return pop
end
function bitset._mt.__index:any_bits_in_common(other)
   assert(other.count == self.count, "union requires both sets to have the same count")
   for n=1,self.intcount do
      if self[n] & other[n] ~= 0 then return true end
   end
   return false
end
function bitset._mt.__index:write(f)
   for n=0,self.count-1 do
      if self:get(n) then io.write("1") else io.write("0") end
   end
end

function bitset.new(count)
   local ret = {}
   setmetatable(ret, bitset._mt)
   ret.count = count
   local intcount = (count + INT_BITS - 1) >> INT_SHIFT
   ret.intcount = intcount
   for n=1,intcount do ret[n] = 0 end
   return ret
end

globals("bitset")
_G.bitset = bitset
