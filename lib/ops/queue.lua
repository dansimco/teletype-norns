-- ops/queue.lua -- port of teletype/src/ops/queue.c
--
-- A 64-slot shift register. Q pushes a value in at the front and reads the
-- value at Q.N - 1; every other op operates on the first Q.N entries. With
-- Q.GRW set, the window grows on write and shrinks on read, which turns it
-- into a queue rather than a fixed window.
--
-- Note the indices: many of these ops read the index into an `int8_t` in the C,
-- so a value above 127 wraps negative before being clamped.

local exec = require 'exec'
local int16 = require 'int16'
local registry = require 'ops.registry'
local st = require 'state'

local impl = registry.impl

local Q_LENGTH = st.Q_LENGTH
local PATTERN_LENGTH = st.PATTERN_LENGTH
local PATTERN_COUNT = st.PATTERN_COUNT

--- reinterpret as int8_t, as the C does when reading an index
local function i8(v)
  v = v & 0xff
  return v >= 0x80 and v - 0x100 or v
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- the shift register itself ----------------------------------------------------

impl('Q',
  function(ss, _es, cs)
    local v = ss.variables
    cs:push(v.q[v.q_n - 1] or 0)
    -- reading shrinks the window when growing is enabled
    if v.q_grow ~= 0 and v.q_n > 1 then v.q_n = v.q_n - 1 end
  end,
  function(ss, _es, cs)
    local v = ss.variables
    for i = Q_LENGTH - 1, 1, -1 do v.q[i] = v.q[i - 1] end
    v.q[0] = cs:pop()
    if v.q_grow ~= 0 and v.q_n < Q_LENGTH then v.q_n = v.q_n + 1 end
  end)

impl('Q.N',
  function(ss, _es, cs) cs:push(ss.variables.q_n) end,
  function(ss, _es, cs) ss.variables.q_n = clamp(cs:pop(), 1, Q_LENGTH) end)

impl('Q.GRW',
  function(ss, _es, cs) cs:push(ss.variables.q_grow) end,
  function(ss, _es, cs)
    local v = ss.variables
    v.q_grow = cs:pop() < 1 and 0 or 1
    if v.q_grow == 0 and v.q_n < 1 then v.q_n = 1 end
  end)

impl('Q.CLR',
  function(ss, _es, _cs)
    local v = ss.variables
    v.q_n = 1
    for i = 0, Q_LENGTH - 1 do v.q[i] = 0 end
  end,
  function(ss, _es, cs)
    local v = ss.variables
    v.q_n = 1
    for i = 0, Q_LENGTH - 1 do v.q[i] = 0 end
    v.q[0] = cs:pop()
  end)

-- aggregates -------------------------------------------------------------------

impl('Q.SUM', function(ss, _es, cs)
  local v = ss.variables
  local sum = 0
  -- accumulated in an int16_t, so a long queue of large values wraps
  for i = 0, v.q_n - 1 do sum = int16.wrap(sum + v.q[i]) end
  cs:push(sum)
end)

impl('Q.AVG',
  function(ss, _es, cs)
    local v = ss.variables
    if v.q_n == 0 then cs:push(0) return end
    local avg = 0
    for i = 0, v.q_n - 1 do avg = avg + v.q[i] end   -- widened to int32
    avg = int16.idiv(avg * 2, v.q_n)
    if int16.imod(avg, 2) ~= 0 then avg = avg + 1 end
    cs:push(int16.idiv(avg, 2))
  end,
  -- setting Q.AVG fills the *whole* register, not just the window
  function(ss, _es, cs)
    local a = cs:pop()
    for i = 0, Q_LENGTH - 1 do ss.variables.q[i] = a end
  end)

--- MIN/MAX read the extreme; setting them clamps the window against a bound
local function extreme(name, better, seed)
  impl(name,
    function(ss, _es, cs)
      local v = ss.variables
      local best = seed
      for i = 0, v.q_n - 1 do
        if better(v.q[i], best) then best = v.q[i] end
      end
      cs:push(best)
    end,
    function(ss, _es, cs)
      local v = ss.variables
      local bound = cs:pop()
      for i = 0, v.q_n - 1 do
        if better(v.q[i], bound) then v.q[i] = bound end
      end
    end)
end

extreme('Q.MIN', function(a, b) return a < b end, int16.MAX)
extreme('Q.MAX', function(a, b) return a > b end, int16.MIN)

-- reordering ---------------------------------------------------------------------

--- selection sort over [lo, hi). shared by both Q.SRT forms.
local function sort_range(q, lo, hi)
  for i = lo, hi - 1 do
    local min, min_idx = int16.MAX, i
    for j = i, hi - 1 do
      if q[j] < min then min = q[j]; min_idx = j end
    end
    q[min_idx], q[i] = q[i], q[min_idx]
  end
end

impl('Q.SRT',
  function(ss, _es, _cs)
    sort_range(ss.variables.q, 0, ss.variables.q_n)
  end,
  -- a positive bound sorts the first n, a negative one sorts from n to the end
  function(ss, _es, cs)
    local v = ss.variables
    local bound = cs:pop()
    local lo, hi
    if bound > 0 then
      lo, hi = 0, i8(bound > v.q_n and v.q_n or bound)
    elseif bound < 0 then
      hi = v.q_n
      lo = i8(-bound > v.q_n and v.q_n or -bound)
    else
      lo, hi = 0, v.q_n
    end
    sort_range(v.q, lo, hi)
  end)

impl('Q.REV', function(ss, _es, _cs)
  local v = ss.variables
  for i = 0, (v.q_n // 2) - 1 do
    v.q[i], v.q[v.q_n - 1 - i] = v.q[v.q_n - 1 - i], v.q[i]
  end
end)

impl('Q.SH',
  -- the no-argument form rotates by one, but note the C reads q[-1] on the
  -- last iteration; that lands on q_grow in the struct. see docs/differences.
  function(ss, _es, _cs)
    local v = ss.variables
    local tmp = v.q[v.q_n - 1]
    for i = v.q_n - 1, 1, -1 do v.q[i] = v.q[i - 1] end
    v.q[0] = tmp
  end,
  function(ss, _es, cs)
    local v = ss.variables
    local n = cs:pop()
    if v.q_n == 0 then return end
    if n > 0 then n = int16.imod(n, v.q_n)
    elseif n < 0 then n = v.q_n - int16.imod(-n, v.q_n) end
    if n == 0 then return end
    local tmp = {}
    for i = 0, v.q_n - 1 do tmp[i] = v.q[i] end
    for i = 0, v.q_n - 1 do v.q[(i + n) % v.q_n] = tmp[i] end
  end)

-- elementwise arithmetic -----------------------------------------------------------
-- the get form applies to the whole window; the set form takes an index too.

local function arith(name, apply, guard_zero)
  impl(name,
    function(ss, _es, cs)
      local v = ss.variables
      local operand = cs:pop()
      if guard_zero and operand == 0 then return end
      for i = 0, v.q_n - 1 do v.q[i] = int16.wrap(apply(v.q[i], operand)) end
    end,
    function(ss, _es, cs)
      local v = ss.variables
      local operand = cs:pop()
      local i = i8(cs:pop())
      if guard_zero and operand == 0 then return end
      i = clamp(i, 0, v.q_n - 1)
      v.q[i] = int16.wrap(apply(v.q[i], operand))
    end)
end

arith('Q.ADD', function(a, b) return a + b end, false)
arith('Q.SUB', function(a, b) return a - b end, false)
arith('Q.MUL', function(a, b) return a * b end, false)
arith('Q.DIV', function(a, b) return int16.idiv(a, b) end, true)
arith('Q.MOD', function(a, b) return int16.imod(a, b) end, true)

impl('Q.I',
  function(ss, _es, cs)
    cs:push(ss.variables.q[clamp(i8(cs:pop()), 0, Q_LENGTH - 1)] or 0)
  end,
  function(ss, _es, cs)
    local i = i8(cs:pop())
    local value = cs:pop()
    ss.variables.q[clamp(i, 0, Q_LENGTH - 1)] = value
  end)

-- pattern interchange ---------------------------------------------------------------

local END_AT = PATTERN_LENGTH < Q_LENGTH and PATTERN_LENGTH or Q_LENGTH

impl('Q.2P',
  function(ss, _es, _cs)
    local pn = ss.variables.p_n
    for i = 0, END_AT - 1 do ss.patterns[pn].val[i] = ss.variables.q[i] end
    exec.io.pattern_updated()
  end,
  function(ss, _es, cs)
    local pn = clamp(cs:pop(), 0, PATTERN_COUNT - 1)
    for i = 0, END_AT - 1 do ss.patterns[pn].val[i] = ss.variables.q[i] end
    exec.io.pattern_updated()
  end)

impl('Q.P2',
  function(ss, _es, _cs)
    local pn = ss.variables.p_n
    for i = 0, END_AT - 1 do ss.variables.q[i] = ss.patterns[pn].val[i] end
  end,
  function(ss, _es, cs)
    local pn = clamp(cs:pop(), 0, PATTERN_COUNT - 1)
    for i = 0, END_AT - 1 do ss.variables.q[i] = ss.patterns[pn].val[i] end
  end)

-- Q.RND ------------------------------------------------------------------------------
-- DIVERGENCE: the C uses stdlib rand(), not teletype's own seedable generator,
-- so its output cannot be reproduced here and is unaffected by SEED even on
-- hardware. We use the scene's pattern generator so the behaviour is at least
-- seedable and deterministic. See docs/differences.md.

impl('Q.RND',
  function(ss, _es, cs)
    local v = ss.variables
    if v.q_n <= 0 then cs:push(0) return end
    cs:push(v.q[int16.imod(ss.rand_states.pattern.rand:next(), v.q_n)] or 0)
  end,
  function(ss, _es, cs)
    local v = ss.variables
    local rnd = cs:pop()
    local r = ss.rand_states.pattern.rand
    if v.q_n <= 0 then return end
    if rnd > 0 then
      for i = 0, v.q_n - 1 do v.q[i] = int16.imod(r:next(), rnd) end
    elseif rnd < 0 then
      -- swap pairs |rnd| times, capped at 3 * q_n swaps
      if rnd < -3 * v.q_n then rnd = -3 * v.q_n end
      for _ = rnd, -1 do
        local a = int16.imod(r:next(), v.q_n)
        local b = int16.imod(r:next(), v.q_n)
        v.q[a], v.q[b] = v.q[b], v.q[a]
      end
    end
  end)
