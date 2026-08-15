-- ops/random_ops.lua -- RAND, RRAND, R, TOSS and the seed ops
-- port of the random half of teletype/src/ops/maths.c plus
-- teletype/src/ops/seed.c
--
-- Five independent generators (rand, prob, toss, pattern, drunk), each
-- separately seedable, so a scene that seeds them replays identically.

local int16 = require 'int16'
local registry = require 'ops.registry'

local impl = registry.impl

--- teletype/src/ops/maths.c:497 -- shared by RRAND and R
local function push_random(a, b, ss)
  local min, max
  if a < b then min, max = a, b else min, max = b, a end
  local range = max - min + 1
  if range == 0 or min == max then return min end
  return int16.imod(ss.rand_states.rand.rand:next(), range) + min
end

impl('RAND', function(ss, _es, cs)
  local a = cs:pop()
  local r = ss.rand_states.rand.rand
  if a < 0 then
    cs:push(-int16.imod(r:next(), 1 - a))
  elseif a == 32767 then
    -- the full-range case returns the raw draw, truncated by push
    cs:push(int16.wrap(r:next()))
  else
    cs:push(int16.imod(r:next(), a + 1))
  end
end)

impl('RRAND', function(ss, _es, cs)
  local a, b = cs:pop(), cs:pop()
  cs:push(push_random(a, b, ss))
end)

-- R draws from the R.MIN..R.MAX range; setting R pins both bounds to one value
impl('R',
  function(ss, _es, cs)
    cs:push(push_random(ss.variables.r_min, ss.variables.r_max, ss))
  end,
  function(ss, _es, cs)
    local v = cs:pop()
    ss.variables.r_min = v
    ss.variables.r_max = v
  end)

impl('R.MIN',
  function(ss, _es, cs) cs:push(ss.variables.r_min) end,
  function(ss, _es, cs) ss.variables.r_min = cs:pop() end)

impl('R.MAX',
  function(ss, _es, cs) cs:push(ss.variables.r_max) end,
  function(ss, _es, cs) ss.variables.r_max = cs:pop() end)

impl('TOSS', function(ss, _es, cs)
  cs:push(ss.rand_states.toss.rand:next() & 1)
end)

-- seeds ----------------------------------------------------------------------
-- teletype/src/ops/seed.c. reading a seed op returns the stored seed; setting
-- it reseeds that generator. SEED sets all five at once.

local function seed_op(name, generator)
  impl(name,
    function(ss, _es, cs) cs:push(ss.rand_states[generator].seed) end,
    function(ss, _es, cs)
      local s = cs:pop()
      ss.rand_states[generator].seed = s
      ss.rand_states[generator].rand:seed(s)
    end)
end

seed_op('RAND.SEED', 'rand')
seed_op('RAND.SD', 'rand')
seed_op('R.SD', 'rand')
seed_op('TOSS.SEED', 'toss')
seed_op('TOSS.SD', 'toss')
seed_op('PROB.SEED', 'prob')
seed_op('PROB.SD', 'prob')
seed_op('DRUNK.SEED', 'drunk')
seed_op('DRUNK.SD', 'drunk')
seed_op('P.SEED', 'pattern')
seed_op('P.SD', 'pattern')

impl('SEED',
  function(ss, _es, cs) cs:push(ss.variables.seed) end,
  function(ss, _es, cs)
    local s = cs:pop()
    ss.variables.seed = s
    for _, state in pairs(ss.rand_states) do
      state.seed = s
      state.rand:seed(s)
    end
  end)
