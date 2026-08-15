-- ops/maths.lua -- arithmetic, comparison, logic and bit ops
-- port of the arithmetic half of teletype/src/ops/maths.c
--
-- Two conventions hold throughout, and they come from the evaluator: words in
-- a sub-command are evaluated right to left, so arguments are pushed in
-- reverse and **the first pop is the leftmost argument**. And every result
-- goes back through CommandState:push, which wraps to int16 -- matching the C,
-- where cs_push takes an int16_t and the compiler truncates at the call.

local int16 = require 'int16'
local helpers = require 'helpers'
local registry = require 'ops.registry'
local T = require 'tables'

local impl = registry.impl

-- Shifts happen on a 32-bit int in the C: the int16 operand is promoted, and
-- the shift count is whatever the hardware does with it -- on x86 and ARM,
-- masked to 5 bits. So `1 << 100` is `1 << 4` = 16, not 0. Reproducing that
-- masking matters: RSH with a negative count is a documented way to shift the
-- other way, and large counts fall out of ordinary arithmetic on scene values.
local function shift_count(n)
  return n & 31
end

-- C's >> on a signed value is an arithmetic shift: it sign-extends, which is
-- floor division by a power of two. lua's >> is logical over 64 bits, so it
-- would turn a negative into a huge positive.
local function asr(x, n)
  if n <= 0 then return x end
  return x // (1 << shift_count(n))
end

local function asl(x, n)
  if n <= 0 then return x end
  return int16.wrap(x << shift_count(n))
end

-- The bit ops (BSET/BGET/BCLR/BTOG) differ from RSH/LSH: they shift with a
-- plain C `<<`/`>>` and have no negative-count special case, so a negative bit
-- index wraps through the 5-bit mask rather than reversing direction. `BSET 0
-- -1` is therefore `1 << 31`, whose low 16 bits are zero.
local function shl32(x, n) return x << shift_count(n) end
local function shr32(x, n) return x // (1 << shift_count(n)) end

-- arithmetic -----------------------------------------------------------------

impl('ADD', function(_ss, _es, cs) cs:push(cs:pop() + cs:pop()) end)
impl('SUB', function(_ss, _es, cs) cs:push(cs:pop() - cs:pop()) end)

-- MUL saturates rather than wrapping: the C widens to int32, clamps, then
-- narrows. so MUL 1000 1000 is 32767, not the wrapped value.
impl('MUL', function(_ss, _es, cs)
  cs:push(int16.clamp(cs:pop() * cs:pop()))
end)

impl('DIV', function(_ss, _es, cs)
  local a, b = cs:pop(), cs:pop()
  cs:push(b ~= 0 and int16.idiv(a, b) or 0)
end)

impl('MOD', function(_ss, _es, cs)
  local a, b = cs:pop(), cs:pop()
  cs:push(b ~= 0 and int16.imod(a, b) or 0)
end)

impl('MIN', function(_ss, _es, cs)
  local a, b = cs:pop(), cs:pop()
  cs:push(b > a and a or b)
end)

impl('MAX', function(_ss, _es, cs)
  local a, b = cs:pop(), cs:pop()
  cs:push(a > b and a or b)
end)

impl('LIM', function(_ss, _es, cs)
  local i, a, b = cs:pop(), cs:pop(), cs:pop()
  if i < a then cs:push(a)
  elseif i > b then cs:push(b)
  else cs:push(i) end
end)

-- WRAP is a true modulo into [a, b), unlike helpers.normalise_value which
-- jumps to the opposite bound. it also handles a reversed range.
local function op_wrap(_ss, _es, cs)
  local i, a, b = cs:pop(), cs:pop(), cs:pop()
  local c
  if a < b then
    c = b - a + 1
    while i >= b do i = i - c end
    while i < a do i = i + c end
  else
    c = a - b + 1
    while i >= a do i = i - c end
    while i < b do i = i + c end
  end
  cs:push(i)
end
impl('WRAP', op_wrap)
impl('WRP', op_wrap)

impl('AVG', function(_ss, _es, cs)
  -- the doubling dance is the C's way of rounding away from zero
  local ret = ((cs:pop() * 2) + (cs:pop() * 2)) // 2
  if int16.imod(ret, 2) ~= 0 then ret = ret + 1 end
  cs:push(int16.idiv(ret, 2))
end)

impl('ABS', function(_ss, _es, cs)
  local a = cs:pop()
  cs:push(a < 0 and -a or a)
end)

impl('SGN', function(_ss, _es, cs)
  local a = cs:pop()
  cs:push(a > 0 and 1 or (a < 0 and -1 or 0))
end)

impl('EXP', function(_ss, _es, cs)
  local a = cs:pop()
  if a > 16383 then a = 16383 elseif a < -16383 then a = -16383 end
  a = asr(a, 6)
  if a < 0 then
    a = -a
    -- the C indexes table_exp[256] here, one past the end; clamping keeps the
    -- lua deterministic where the C reads whatever follows the array
    cs:push(-(T.table_exp[a] or T.table_exp[255]))
  else
    cs:push(T.table_exp[a] or T.table_exp[255])
  end
end)

impl('BPM', function(_ss, _es, cs)
  local a = cs:pop()
  if a < 2 then a = 2 end
  if a > 1000 then a = 1000 end
  -- fixed-point ms-per-beat, computed in uint32 exactly as the C does
  local ret = (((1 << 31) // ((a << 20) // 60)) * 1000) >> 10
  ret = ret // 2 + (ret & 1)
  cs:push(int16.wrap(ret))
end)

-- comparison -----------------------------------------------------------------
-- every predicate pushes 1 or 0

local function bool_push(cs, v) cs:push(v and 1 or 0) end

impl('EQ', function(_ss, _es, cs) bool_push(cs, cs:pop() == cs:pop()) end)
impl('NE', function(_ss, _es, cs) bool_push(cs, cs:pop() ~= cs:pop()) end)
impl('LT', function(_ss, _es, cs) bool_push(cs, cs:pop() < cs:pop()) end)
impl('GT', function(_ss, _es, cs) bool_push(cs, cs:pop() > cs:pop()) end)
impl('LTE', function(_ss, _es, cs) bool_push(cs, cs:pop() <= cs:pop()) end)
impl('GTE', function(_ss, _es, cs) bool_push(cs, cs:pop() >= cs:pop()) end)

impl('INR', function(_ss, _es, cs)
  local lo, x, hi = cs:pop(), cs:pop(), cs:pop()
  bool_push(cs, lo < x and x < hi)
end)

impl('OUTR', function(_ss, _es, cs)
  local lo, x, hi = cs:pop(), cs:pop(), cs:pop()
  bool_push(cs, lo > x or x > hi)
end)

impl('INRI', function(_ss, _es, cs)
  local lo, x, hi = cs:pop(), cs:pop(), cs:pop()
  bool_push(cs, lo <= x and x <= hi)
end)

impl('OUTRI', function(_ss, _es, cs)
  local lo, x, hi = cs:pop(), cs:pop(), cs:pop()
  bool_push(cs, lo >= x or x >= hi)
end)

impl('NZ', function(_ss, _es, cs) bool_push(cs, cs:pop() ~= 0) end)
impl('EZ', function(_ss, _es, cs) bool_push(cs, cs:pop() == 0) end)

impl('?', function(_ss, _es, cs)
  local condition, a, b = cs:pop(), cs:pop(), cs:pop()
  cs:push(condition ~= 0 and a or b)
end)

-- logical --------------------------------------------------------------------
-- these are logical, not bitwise: AND 2 4 is 1, not 0

impl('AND', function(_ss, _es, cs)
  local a, b = cs:pop(), cs:pop()
  bool_push(cs, a ~= 0 and b ~= 0)
end)

impl('OR', function(_ss, _es, cs)
  local a, b = cs:pop(), cs:pop()
  bool_push(cs, a ~= 0 or b ~= 0)
end)

impl('AND3', function(_ss, _es, cs)
  local a, b, c = cs:pop(), cs:pop(), cs:pop()
  bool_push(cs, a ~= 0 and b ~= 0 and c ~= 0)
end)

impl('OR3', function(_ss, _es, cs)
  local a, b, c = cs:pop(), cs:pop(), cs:pop()
  bool_push(cs, a ~= 0 or b ~= 0 or c ~= 0)
end)

impl('AND4', function(_ss, _es, cs)
  local a, b, c, d = cs:pop(), cs:pop(), cs:pop(), cs:pop()
  bool_push(cs, a ~= 0 and b ~= 0 and c ~= 0 and d ~= 0)
end)

impl('OR4', function(_ss, _es, cs)
  local a, b, c, d = cs:pop(), cs:pop(), cs:pop(), cs:pop()
  bool_push(cs, a ~= 0 or b ~= 0 or c ~= 0 or d ~= 0)
end)

-- bitwise --------------------------------------------------------------------

impl('|', function(_ss, _es, cs) cs:push(cs:pop() | cs:pop()) end)
impl('&', function(_ss, _es, cs) cs:push(cs:pop() & cs:pop()) end)
impl('^', function(_ss, _es, cs) cs:push(cs:pop() ~ cs:pop()) end)
impl('~', function(_ss, _es, cs) cs:push(~cs:pop()) end)

impl('RSH', function(_ss, _es, cs)
  local x, n = cs:pop(), cs:pop()
  cs:push(n > 0 and asr(x, n) or asl(x, -n))
end)

impl('LSH', function(_ss, _es, cs)
  local x, n = cs:pop(), cs:pop()
  cs:push(n > 0 and asl(x, n) or asr(x, -n))
end)

-- rotates operate on the 16-bit pattern, so they go through the unsigned view
local function rrot(x, n) return ((x >> n) | (x << (16 - n))) & 0xffff end
local function lrot(x, n) return ((x << n) | (x >> (16 - n))) & 0xffff end

impl('RROT', function(_ss, _es, cs)
  local u = int16.to_u16(cs:pop())
  local n = int16.imod(cs:pop(), 16)
  u = n > 0 and rrot(u, n) or lrot(u, -n)
  cs:push(int16.from_u16(u))
end)

impl('LROT', function(_ss, _es, cs)
  local u = int16.to_u16(cs:pop())
  local n = int16.imod(cs:pop(), 16)
  u = n > 0 and lrot(u, n) or rrot(u, -n)
  cs:push(int16.from_u16(u))
end)

impl('BSET', function(_ss, _es, cs)
  local v, b = cs:pop(), cs:pop()
  cs:push(v | shl32(1, b))
end)

impl('BGET', function(_ss, _es, cs)
  local v, b = cs:pop(), cs:pop()
  cs:push(shr32(v, b) & 1)
end)

impl('BCLR', function(_ss, _es, cs)
  local v, b = cs:pop(), cs:pop()
  cs:push(v & ~shl32(1, b))
end)

impl('BTOG', function(_ss, _es, cs)
  local v, b = cs:pop(), cs:pop()
  if (shr32(v, b) & 1) ~= 0 then
    cs:push(v & ~shl32(1, b))
  else
    cs:push(v | shl32(1, b))
  end
end)

impl('BREV', function(_ss, _es, cs)
  cs:push(helpers.bit_reverse(cs:pop(), 16))
end)

-- scaling --------------------------------------------------------------------

local function scale(a, b, x, y, i)
  if (b - a) == 0 then return 0 end
  -- computed in int32: the doubling is the C's rounding idiom again
  local result = int16.idiv((i - a) * (y - x) * 2, (b - a))
  result = int16.idiv(result, 2) + (result & 1)
  return result + x
end

impl('SCALE', function(_ss, _es, cs)
  local a, b, x, y, i = cs:pop(), cs:pop(), cs:pop(), cs:pop(), cs:pop()
  cs:push(scale(a, b, x, y, i))
end)

impl('SCALE0', function(_ss, _es, cs)
  local b, y, i = cs:pop(), cs:pop(), cs:pop()
  cs:push(scale(0, b, 0, y, i))
end)

-- aliases --------------------------------------------------------------------
-- these share a getter with a named op; the reference declares them as
-- MAKE_ALIAS_OP with the same function pointer.

local ALIASES = {
  ['+'] = 'ADD', ['-'] = 'SUB', ['*'] = 'MUL',
  ['/'] = 'DIV', ['%'] = 'MOD',
  ['=='] = 'EQ', ['!='] = 'NE', ['XOR'] = 'NE',
  ['<'] = 'LT', ['>'] = 'GT', ['<='] = 'LTE', ['>='] = 'GTE',
  ['><'] = 'INR', ['<>'] = 'OUTR', ['>=<'] = 'INRI', ['<=>'] = 'OUTRI',
  ['!'] = 'EZ',
  ['<<'] = 'LSH', ['>>'] = 'RSH', ['<<<'] = 'LROT', ['>>>'] = 'RROT',
  ['&&'] = 'AND', ['||'] = 'OR',
  ['&&&'] = 'AND3', ['|||'] = 'OR3',
  ['&&&&'] = 'AND4', ['||||'] = 'OR4',
  ['SCL'] = 'SCALE', ['SCL0'] = 'SCALE0',
  ['RND'] = 'RAND', ['RRND'] = 'RRAND',
  ['WRP'] = 'WRAP',
}

--- wire the aliases up once every target exists.
-- called from ops/init.lua after all op modules have loaded, because some
-- targets (RAND, RRAND) live in other files.
function ALIASES.apply()
  for alias, target in pairs(ALIASES) do
    if alias ~= 'apply' then
      local t = registry.ops[registry.by_name[target]]
      impl(alias, t.get, t.set)
    end
  end
end

return ALIASES
