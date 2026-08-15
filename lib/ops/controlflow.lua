-- ops/controlflow.lua -- port of teletype/src/ops/controlflow.c
--
-- The mods here are the only things that receive the POST half of a command.
-- Everything stateful lives in the execution frame (es:vars()), which is what
-- makes IF/ELIF/ELSE chains work across lines of a script and lets a loop body
-- reach into the loop counter.

local exec = require 'exec'
local int16 = require 'int16'
local registry = require 'ops.registry'
local st = require 'state'

local impl = registry.impl
local impl_mod = registry.impl_mod

-- every_count_t helpers, teletype/src/every.c ---------------------------------

local function every_set_mod(e, m)
  if m < 0 then m = -m elseif m == 0 then m = 1 end  -- lazy init
  e.mod = m
  e.count = int16.imod(e.count, e.mod)
end

local function every_tick(e)
  e.count = int16.imod(e.count + 1, e.mod)
end

-- ------------------------------------------------------------------ IF chain
-- if_else_condition records whether any branch of the current chain has fired.
-- It lives in the exec frame and is *inherited* on push, so a SCRIPT called
-- from inside an IF sees it.

impl_mod('IF', function(ss, es, cs, post)
  local a = cs:pop()
  es:vars().if_else_condition = false
  if a ~= 0 then
    es:vars().if_else_condition = true
    exec.process_command(ss, es, post)
  end
end)

impl_mod('ELIF', function(ss, es, cs, post)
  local a = cs:pop()
  if not es:vars().if_else_condition then
    if a ~= 0 then
      es:vars().if_else_condition = true
      exec.process_command(ss, es, post)
    end
  end
end)

impl_mod('ELSE', function(ss, es, _cs, post)
  if not es:vars().if_else_condition then
    es:vars().if_else_condition = true
    exec.process_command(ss, es, post)
  end
end)

-- --------------------------------------------------------------------- loops

impl_mod('L', function(ss, es, cs, post)
  local a, b = cs:pop(), cs:pop()
  local v = es:vars()

  -- I is read and written through the frame rather than a local, so the loop
  -- body can assign to I to skip ahead or roll back
  v.i = a

  if a < b then
    -- the counter is tracked separately and at wider precision so that b ==
    -- 32767 terminates instead of wrapping forever
    local l = a
    while l <= b do
      exec.process_command(ss, es, post)
      if v.breaking then break end
      v.i = int16.wrap(v.i + 1)
      l = l + 1
    end
    if not v.breaking then v.i = int16.wrap(v.i - 1) end
  else
    local l = a
    while l >= b and not v.breaking do
      exec.process_command(ss, es, post)
      v.i = int16.wrap(v.i - 1)
      l = l - 1
    end
    if not v.breaking then v.i = int16.wrap(v.i + 1) end
  end
end)

-- W runs the POST once and raises while_continue; the *caller*
-- (exec.run_range) re-runs the whole line while that stays set.
impl_mod('W', function(ss, es, cs, post)
  local a = cs:pop()
  local v = es:vars()
  if a ~= 0 then
    exec.process_command(ss, es, post)
    v.while_depth = v.while_depth + 1
    v.while_continue = v.while_depth < st.WHILE_DEPTH
  else
    v.while_continue = false
  end
end)

-- ------------------------------------------------------------- EVERY / SKIP
-- The counter is per (script, line), so the same EVERY on two lines counts
-- independently. every_last records which way the last one went, for OTHER.

local function every_common(ss, es, cs, post, skip)
  local mod_value = cs:pop()
  local v = es:vars()
  if v.script_number >= st.TOTAL_SCRIPT_COUNT then return end

  local every = ss:every(v.script_number, v.line_number)
  every.skip = skip
  every_set_mod(every, mod_value)
  every_tick(every)

  local now
  if skip then now = every.count ~= 0 else now = every.count == 0 end
  ss.every_last = now
  if now then exec.process_command(ss, es, post) end
end

impl_mod('EVERY', function(ss, es, cs, post) every_common(ss, es, cs, post, false) end)
impl_mod('EV', function(ss, es, cs, post) every_common(ss, es, cs, post, false) end)
impl_mod('SKIP', function(ss, es, cs, post) every_common(ss, es, cs, post, true) end)

impl_mod('OTHER', function(ss, es, _cs, post)
  if not ss.every_last then exec.process_command(ss, es, post) end
end)

impl_mod('PROB', function(ss, es, cs, post)
  local a = cs:pop()
  if int16.imod(ss.rand_states.prob.rand:next(), 100) < a then
    exec.process_command(ss, es, post)
  end
end)

--- SYNC realigns every EVERY/SKIP counter in the scene. state.c:444
impl('SYNC', function(ss, _es, cs)
  local count = cs:pop()
  ss.every_last = false
  for s = 0, st.TOTAL_SCRIPT_COUNT - 1 do
    for line = 0, st.SCRIPT_MAX_COMMANDS - 1 do
      local e = ss.scripts[s].every[line]
      if e.mod == 0 then e.mod = 1 end
      local c = count
      while c < 0 do c = c + e.mod end
      e.count = c
    end
  end
end)

-- ------------------------------------------------------------------ scripts

impl('SCRIPT',
  function(_ss, es, cs)
    -- 1-based for the user; LIVE and the scratch scripts report 0
    local sn = es:vars().script_number + 1
    if sn > st.EDITABLE_SCRIPT_COUNT then sn = 0 end
    cs:push(sn)
  end,
  function(ss, es, cs)
    local a = cs:pop() - 1
    if a >= st.EDITABLE_SCRIPT_COUNT or a < 0 then return end
    es:push()
    -- once the frame stack overflows every later SCRIPT call is refused; that
    -- is the recursion guard, and it is deliberately sticky
    if not es.overflow then
      exec.run_script_with_exec_state(ss, es, a)
      es:pop()
    end
  end)

impl('SCRIPT.POL',
  function(ss, _es, cs)
    local a = cs:pop() - 1
    if a >= st.TRIGGER_INPUTS or a < 0 then cs:push(0) return end
    cs:push(ss.variables.script_pol[a])
  end,
  function(ss, _es, cs)
    local a = cs:pop() & 0xff     -- read into a uint8_t in the C
    local pol = cs:pop() & 0xff
    if pol > 3 then return end
    -- ss_set_script_pol also calls tele_mute() so the UI redraws its
    -- indicators; setting all eight therefore emits eight notifications
    local function set_pol(i)
      if i >= st.TRIGGER_INPUTS then return end
      ss.variables.script_pol[i] = pol
      exec.io.mute()
    end
    if a == 0 then
      for i = 0, st.TRIGGER_INPUTS - 1 do set_pol(i) end
    else
      local s = a - 1
      if s >= 0 then set_pol(s) end
    end
  end)

impl('BREAK', function(_ss, es, _cs) es:vars().breaking = true end)

impl('KILL', function(ss, _es, _cs)
  ss.stack_op.top = 0
  exec.io.has_stack(false)
  ss.variables.m_act = 0
  exec.io.metro_updated()
  exec.clear_delays(ss)
  exec.io.kill()
end)

-- ------------------------------------------------------------------- scenes

impl('SCENE',
  function(ss, _es, cs) cs:push(ss.variables.scene) end,
  function(ss, _es, cs)
    local scene = cs:pop()
    -- scene changes are suppressed while the INIT script runs, so a scene
    -- cannot load another one at startup
    if not ss.initializing then
      ss.variables.scene = scene
      exec.io.scene(scene, 1, 1)
    end
  end)

local function scene_partial(name, init_grid, init_pattern)
  impl(name, function(ss, _es, cs)
    local scene = cs:pop()
    if not ss.initializing then
      ss.variables.scene = scene
      exec.io.scene(scene, init_grid, init_pattern)
    end
  end)
end

scene_partial('SCENE.G', 0, 1)   -- keep current grid state
scene_partial('SCENE.P', 1, 0)   -- keep current patterns

-- ----------------------------------------------------------------- functions
-- $F / $L / $S call a script or a single line as a function, with up to two
-- arguments readable as I1/I2 and a result set via FR.

local function execute_function(script, ss, es, param1, param2)
  if script >= st.EDITABLE_SCRIPT_COUNT or script < 0 then return 0 end
  local result = 0
  es:push(param1, param2)
  if not es.overflow then
    local has_value, value = exec.run_fscript_with_exec_state(ss, es, script)
    if has_value then result = value end
    es:pop()
  end
  return result
end

local function execute_function_line(script, line, ss, es, param1, param2)
  if script >= st.EDITABLE_SCRIPT_COUNT or script < 0 then return 0 end
  if line >= ss:script_len(script) or line < 0 then return 0 end
  local result = 0
  es:push(param1, param2)
  if not es.overflow then
    local has_value, value =
      exec.run_fline_with_exec_state(ss, es, script, line)
    if has_value then result = value end
    es:pop()
  end
  return result
end

-- the script/line indices are read into uint8_t in the C, so a 0 argument
-- becomes 255 rather than -1 and fails the range test either way
local function u8(v) return v & 0xff end

impl('$F', function(ss, es, cs)
  local script = u8(cs:pop() - 1)
  cs:push(execute_function(script, ss, es, 0, 0))
end)

impl('$F1', function(ss, es, cs)
  local script = u8(cs:pop() - 1)
  local p1 = cs:pop()
  cs:push(execute_function(script, ss, es, p1, 0))
end)

impl('$F2', function(ss, es, cs)
  local script = u8(cs:pop() - 1)
  local p1, p2 = cs:pop(), cs:pop()
  cs:push(execute_function(script, ss, es, p1, p2))
end)

impl('$L', function(ss, es, cs)
  local script = u8(cs:pop() - 1)
  local line = u8(cs:pop() - 1)
  cs:push(execute_function_line(script, line, ss, es, 0, 0))
end)

impl('$L1', function(ss, es, cs)
  local script = u8(cs:pop() - 1)
  local line = u8(cs:pop() - 1)
  local p1 = cs:pop()
  cs:push(execute_function_line(script, line, ss, es, p1, 0))
end)

impl('$L2', function(ss, es, cs)
  local script = u8(cs:pop() - 1)
  local line = u8(cs:pop() - 1)
  local p1, p2 = cs:pop(), cs:pop()
  cs:push(execute_function_line(script, line, ss, es, p1, p2))
end)

-- $S variants target a line of the *current* script
impl('$S', function(ss, es, cs)
  local script = es:vars().script_number
  local line = u8(cs:pop() - 1)
  cs:push(execute_function_line(script, line, ss, es, 0, 0))
end)

impl('$S1', function(ss, es, cs)
  local script = es:vars().script_number
  local line = u8(cs:pop() - 1)
  local p1 = cs:pop()
  cs:push(execute_function_line(script, line, ss, es, p1, 0))
end)

impl('$S2', function(ss, es, cs)
  local script = es:vars().script_number
  local line = u8(cs:pop() - 1)
  local p1, p2 = cs:pop(), cs:pop()
  cs:push(execute_function_line(script, line, ss, es, p1, p2))
end)

impl('I1', function(_ss, es, cs) cs:push(es:vars().fparam1) end)
impl('I2', function(_ss, es, cs) cs:push(es:vars().fparam2) end)

impl('FR',
  function(_ss, es, cs) cs:push(es:vars().fresult) end,
  function(_ss, es, cs)
    local v = es:vars()
    v.fresult = cs:pop()
    v.fresult_set = true
  end)

-- aliases sharing a getter
local function alias(name, target)
  local t = registry.ops[registry.by_name[target]]
  impl(name, t.get, t.set)
end

alias('$', 'SCRIPT')
alias('$.POL', 'SCRIPT.POL')
alias('BRK', 'BREAK')
