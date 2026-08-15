-- random.lua
--
-- port of libavr32/src/random.c -- a pair of concatenated 16-bit
-- multiply-with-carry generators. we reproduce it exactly rather than reaching
-- for math.random, because teletype exposes six independently seedable
-- generators (SEED, RAND.SEED, TOSS.SEED, PROB.SEED, DRUNK.SEED, P.SEED) and a
-- seeded scene is expected to replay identically to the hardware.

local Random = {}
Random.__index = Random

local U32 = 0xffffffff

function Random.new(seed)
  local r = setmetatable({ z = 0, w = 0 }, Random)
  r:seed(seed or 0)
  return r
end

--- (re)seed, restarting the sequence. libavr32/src/random.c:3
function Random:seed(s)
  s = s & U32
  self.z = (~s) & U32
  self.w = s
end

--- next value in [0, 0x7FFFFFFF]. libavr32/src/random.c:12
function Random:next()
  self.z = (36969 * (self.z & 0xffff) + (self.z >> 16)) & U32
  self.w = (18000 * (self.w & 0xffff) + (self.w >> 16)) & U32
  return (((self.z << 16) & U32) + self.w) & 0x7FFFFFFF
end

return Random
