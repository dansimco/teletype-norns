-- ops/rhythm.lua -- ER, NR and the DR.* drum ops
-- ports of the rhythm half of teletype/src/ops/maths.c plus
-- teletype/src/drum_helpers.c
--
-- These are all table lookups. The drum patterns are bit-packed MSB-first,
-- one row per pattern, and the euclidean patterns are pre-resolved into one
-- bitmask per (fill, length) -- see tools/gen_tables.lua.

local int16 = require 'int16'
local registry = require 'ops.registry'
local T = require 'tables'

local impl = registry.impl

local DRUM_PATTERN_LEN = 216   -- drum_ops_pattern_len

--- modulo into [lower, upper]. drum_helpers.c:7
local function wrap(k, lower, upper)
  local range = upper - lower + 1
  if range <= 0 then return lower end
  local kx = int16.imod(k - lower, range)
  if kx < 0 then return upper + 1 + kx end
  return lower + kx
end

--- bit k of a row packed MSB-first across `bytes` bytes. drum_helpers.c:21
local function get_bit(row, bytes, k)
  local total = bytes * 8
  if k < 0 or k >= total then return 0 end
  return (row >> (total - 1 - k)) & 1
end

-- the five drum banks, in the order the C switch uses
local BANKS = {
  [0] = { table = 'table_t_r_e', bytes = 3 },
  [1] = { table = 'table_dr_bd', bytes = 2 },
  [2] = { table = 'table_dr_sd', bytes = 2 },
  [3] = { table = 'table_dr_ch', bytes = 2 },
  [4] = { table = 'table_dr_oh', bytes = 2 },
}

--- ER fill len step -- euclidean rhythm, 1 when the step is a hit
impl('ER', function(_ss, _es, cs)
  local fill, len, step = cs:pop(), cs:pop(), cs:pop()
  local row = T.euclidean[fill] and T.euclidean[fill][len]
  if not row then cs:push(0) return end
  -- the table resolves 32 steps; beyond that the pattern repeats by length
  local s = len > 0 and (step % len) or 0
  if s < 0 then s = s + len end
  if s >= 32 then cs:push(0) return end
  cs:push((row >> s) & 1)
end)

--- NR prime mask factor step -- numeric repetitor
impl('NR', function(_ss, _es, cs)
  local prime = int16.imod(cs:pop(), 32)
  if prime < 0 then prime = 32 + prime end
  local rhythm = T.table_nr[prime] & 0xffff
  local mask = int16.imod(cs:pop(), 4)
  if mask < 0 then mask = 4 + mask end
  local factor = int16.imod(cs:pop(), 17)
  if factor < 0 then factor = 17 + factor end
  local step = int16.imod(cs:pop(), 16)
  if step < 0 then step = 16 + step end

  if mask == 1 then rhythm = rhythm & 0x0F0F
  elseif mask == 2 then rhythm = rhythm & 0xF003
  elseif mask == 3 then rhythm = rhythm & 0x1F0 end

  -- the multiply is done in uint32 and then folded back into 16 bits
  local modified = (rhythm * factor) & 0xffffffff
  local final = ((modified & 0xffff) | (modified >> 16)) & 0xffff
  cs:push((final >> (15 - step)) & 1)
end)

--- DR.T bank p1 p2 len step -- tresillo: three-three-two over two patterns
impl('DR.T', function(_ss, _es, cs)
  local bank = cs:pop()
  local pattern1 = cs:pop()
  local pattern2 = cs:pop()
  local len = cs:pop()
  local step = cs:pop()

  if bank < 0 or bank > 4 then cs:push(0) return end
  if len < 8 then cs:push(0) return end
  if step < 0 then cs:push(0) return end
  if pattern1 >= DRUM_PATTERN_LEN or pattern2 >= DRUM_PATTERN_LEN then
    cs:push(0) return
  end
  if pattern1 < 0 or pattern2 < 0 then cs:push(0) return end

  local b = BANKS[bank]
  local row1 = T[b.table][pattern1]
  local row2 = T[b.table][pattern2]

  local multiplier = len // 8
  local three = 3 * multiplier
  local wrapped = wrap(step, 0, multiplier * 8 - 1)

  -- the first two groups of three come from pattern1, the tail from pattern2
  if wrapped <= three - 1 then
    cs:push(get_bit(row1, b.bytes, wrapped))
  elseif wrapped <= three * 2 - 1 then
    cs:push(get_bit(row1, b.bytes, wrapped - three))
  else
    cs:push(get_bit(row2, b.bytes, wrapped - three * 2))
  end
end)

--- DR.P bank pattern step -- one 16-step drum pattern
impl('DR.P', function(_ss, _es, cs)
  local bank, pattern, step = cs:pop(), cs:pop(), cs:pop()
  if bank < 0 or bank > 4 then cs:push(0) return end
  if step < 0 then cs:push(0) return end
  if pattern >= DRUM_PATTERN_LEN or pattern < 0 then cs:push(0) return end
  local b = BANKS[bank]
  cs:push(get_bit(T[b.table][pattern], b.bytes, wrap(step, 0, 15)))
end)

--- DR.V pattern step -- velocity for a 16-step pattern
impl('DR.V', function(_ss, _es, cs)
  local pattern, step = cs:pop(), cs:pop()
  if step < 0 then cs:push(0) return end
  if pattern < 0 or pattern > 19 then cs:push(0) return end
  cs:push(T.table_vel_helper[pattern][wrap(step, 0, 15)])
end)
