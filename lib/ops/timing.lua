-- ops/timing.lua -- the delay queue, the command stack and the metronome
-- ports of teletype/src/ops/delay.c, stack.c and metronome.c
--
-- These three are what make a Teletype scene move on its own, and they are the
-- ops Phase 4 has to give a real clock to. The delay queue holds 64 pending
-- commands, decremented by exec.tick(); the command stack holds 16 commands to
-- be fired together; the metronome just holds a period and asks the host to
-- retime itself.

local command = require 'command'
local exec = require 'exec'
local helpers = require 'helpers'
local int16 = require 'int16'
local registry = require 'ops.registry'
local st = require 'state'

local impl = registry.impl
local impl_mod = registry.impl_mod

-- delay ------------------------------------------------------------------------

--- queue one command. delay.c:43
-- Returns false when the queue is full, which is what stops the repeating
-- forms early. Note that 0 marks an empty slot, so a delay of 0 is bumped to
-- 1 rather than vanishing.
local function delay_add(ss, es, delay_time, post)
  local i = 0
  while i < st.DELAY_SIZE and ss.delay.time[i] ~= 0 do i = i + 1 end

  if delay_time < 1 then delay_time = 1 end

  if i < st.DELAY_SIZE then
    ss.delay.count = ss.delay.count + 1
    ss.delay.time[i] = delay_time
    -- the originating context travels with the command, so THIS, I and the
    -- function arguments still resolve when it fires
    local v = es:vars()
    ss.delay.origin_script[i] = v.script_number
    ss.delay.origin_i[i] = v.i
    ss.delay.origin_fparam1[i] = v.fparam1
    ss.delay.origin_fparam2[i] = v.fparam2
    ss.delay.commands[i] = command.copy(post)
    return true
  end
  return false
end

local function notify(ss)
  exec.io.has_delays(ss.delay.count > 0)
end

impl_mod('DEL', function(ss, es, cs, post)
  delay_add(ss, es, cs:pop(), post)
  notify(ss)
end)

--- DEL.X n t: n copies, evenly spaced t apart, the first at t.
impl_mod('DEL.X', function(ss, es, cs, post)
  local num = cs:pop()
  local delay_time = cs:pop()
  if delay_time < 1 then delay_time = 1 end
  local next_time = delay_time
  while num > 0 and delay_add(ss, es, next_time, post) do
    next_time = helpers.normalise_value(1, 32767, 1,
      int16.wrap(next_time + delay_time))
    num = num - 1
  end
  notify(ss)
end)

--- DEL.R n t: same, but the first fires immediately (1ms).
impl_mod('DEL.R', function(ss, es, cs, post)
  local num = cs:pop()
  local delay_time = cs:pop()
  if delay_time < 1 then delay_time = 1 end
  local next_time = 1
  while num > 0 and delay_add(ss, es, next_time, post) do
    next_time = helpers.normalise_value(1, 32767, 1,
      int16.wrap(next_time + delay_time))
    num = num - 1
  end
  notify(ss)
end)

--- DEL.G n t num denom: geometric -- the gap is scaled by num/denom each time.
impl_mod('DEL.G', function(ss, es, cs, post)
  local num = cs:pop()
  local delay_time = cs:pop()
  local mult_num = cs:pop()
  local mult_denom = cs:pop()
  if delay_time < 1 then delay_time = 1 end
  local next_time = 1
  while num > 0 and delay_add(ss, es, next_time, post) do
    next_time = helpers.normalise_value(1, 32767, 1,
      int16.wrap(next_time + delay_time))
    if mult_denom ~= 0 then
      delay_time = int16.wrap(int16.idiv(delay_time * mult_num, mult_denom))
    end
    num = num - 1
  end
  notify(ss)
end)

--- DEL.B t mask: one delay per set bit of the mask, bit i at i * t.
-- bit 0 fires immediately.
impl_mod('DEL.B', function(ss, es, cs, post)
  local base_time = cs:pop()
  if base_time < 1 then base_time = 1 end
  local mask = cs:pop()
  for i = 0, 15 do
    if ((mask >> i) & 1) == 1 then
      local next_time
      if i == 0 then
        next_time = 1
      else
        next_time = helpers.normalise_value(1, 32767, 0, int16.wrap(i * base_time))
      end
      delay_add(ss, es, next_time, post)
    end
  end
  notify(ss)
end)

impl('DEL.CLR', function(ss, _es, _cs) exec.clear_delays(ss) end)

-- command stack ------------------------------------------------------------------
-- S queues a command; S.ALL fires everything, S.POP fires the most recent.
-- Note S.ALL drains in *insertion* order despite the stack framing.

impl_mod('S', function(ss, _es, _cs, post)
  if ss.stack_op.top < st.STACK_OP_SIZE then
    ss.stack_op.commands[ss.stack_op.top] = command.copy(post)
    ss.stack_op.top = ss.stack_op.top + 1
    exec.io.has_stack(ss.stack_op.top > 0)
  end
end)

impl('S.ALL', function(ss, es, _cs)
  local top = ss.stack_op.top
  for i = 0, top - 1 do
    exec.process_command(ss, es, ss.stack_op.commands[top - i - 1])
  end
  ss.stack_op.top = 0
  exec.io.has_stack(false)
end)

impl('S.POP', function(ss, es, _cs)
  if ss.stack_op.top > 0 then
    ss.stack_op.top = ss.stack_op.top - 1
    exec.process_command(ss, es, ss.stack_op.commands[ss.stack_op.top])
    if ss.stack_op.top == 0 then exec.io.has_stack(false) end
  end
end)

impl('S.CLR', function(ss, _es, _cs)
  ss.stack_op.top = 0
  exec.io.has_stack(false)
end)

impl('S.L', function(ss, _es, cs) cs:push(ss.stack_op.top) end)

-- metronome ------------------------------------------------------------------------
-- M holds the period in ms; the host retimes its metro on metro_updated().

local function metro_op(name, floor_ms)
  impl(name,
    function(ss, _es, cs) cs:push(ss.variables.m) end,
    function(ss, _es, cs)
      local m = cs:pop()
      if m < floor_ms then m = floor_ms end
      ss.variables.m = m
      exec.io.metro_updated()
    end)
end

metro_op('M', st.METRO_MIN_MS)
-- M! allows periods below the supported minimum; upstream marks it experimental
metro_op('M!', st.METRO_MIN_UNSUPPORTED_MS)

impl('M.ACT',
  function(ss, _es, cs) cs:push(ss.variables.m_act) end,
  function(ss, _es, cs)
    ss.variables.m_act = (cs:pop() > 0) and 1 or 0
    exec.io.metro_updated()
  end)

impl('M.RESET', function(_ss, _es, _cs) exec.io.metro_reset() end)
