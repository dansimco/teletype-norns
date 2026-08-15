-- ops/init_ops.lua -- the INIT.* family and the CHAOS ops
-- ports of teletype/src/ops/init.c and the chaos ops in maths.c
--
-- INIT resets parts of the scene. Note that calibration survives a full reset
-- (it describes the hardware, not the scene) and that CHAOS state is a global
-- in the C, so it survives too.

local chaos = require 'chaos'
local exec = require 'exec'
local registry = require 'ops.registry'
local scale = require 'scale'
local st = require 'state'

local impl = registry.impl

--- rebuild the IN/PARAM scales from the current calibration and ranges
local function update_scales(ss)
  ss.variables.in_scale = scale.init(ss.cal.i_min, ss.cal.i_max,
    ss.variables.in_range[1], ss.variables.in_range[2])
  ss.variables.param_scale = scale.init(ss.cal.p_min, ss.cal.p_max,
    ss.variables.param_range[1], ss.variables.param_range[2])
end

--- full scene reset. init.c:57
-- Calibration is cached across the reset because it lives in flash on the
-- hardware and describes the module, not the scene.
local function init_scene(ss)
  local cal = ss.cal
  local fresh = st.SceneState.new(0)
  for k, v in pairs(fresh) do ss[k] = v end
  ss.cal = cal
  update_scales(ss)
  -- ss_variables_init calls tele_update_adc(1) on the way through
  exec.io.update_adc(1)
  exec.io.vars_updated()
  exec.io.metro_updated()
end

impl('INIT', function(ss, _es, _cs) init_scene(ss) end)
impl('INIT.SCENE', function(ss, _es, _cs) init_scene(ss) end)

impl('INIT.SCRIPT', function(ss, _es, cs)
  local v = cs:pop() - 1
  if v >= 0 and v < st.EDITABLE_SCRIPT_COUNT then ss:clear_script(v) end
end)

impl('INIT.SCRIPT.ALL', function(ss, _es, _cs)
  for i = 0, st.EDITABLE_SCRIPT_COUNT - 1 do ss:clear_script(i) end
end)

--- reset one pattern to its defaults. note this one is 0-indexed, unlike the
--- script and CV forms either side of it.
local function pattern_init(ss, n)
  local p = ss.patterns[n]
  p.idx, p.len, p.wrap, p.start, p['end'] = 0, 0, 1, 0, 63
  for i = 0, st.PATTERN_LENGTH - 1 do p.val[i] = 0 end
end

impl('INIT.P', function(ss, _es, cs)
  local v = cs:pop()
  if v >= 0 and v < st.PATTERN_COUNT then
    pattern_init(ss, v)
    exec.io.pattern_updated()
  end
end)

impl('INIT.P.ALL', function(ss, _es, _cs)
  for i = 0, st.PATTERN_COUNT - 1 do pattern_init(ss, i) end
  exec.io.pattern_updated()
end)

local function cv_init(ss, i)
  ss.variables.cv[i] = 0
  ss.variables.cv_off[i] = 0
  ss.variables.cv_slew[i] = 1
  exec.io.cv(i, 0, 1)
end

impl('INIT.CV', function(ss, _es, cs)
  local v = cs:pop() - 1
  if v >= 0 and v < st.TR_COUNT then cv_init(ss, v) end
end)

impl('INIT.CV.ALL', function(ss, _es, _cs)
  for i = 0, st.TR_COUNT - 1 do cv_init(ss, i) end
end)

local function tr_init(ss, i)
  ss.variables.tr[i] = 0
  ss.variables.tr_pol[i] = 1
  ss.variables.tr_time[i] = 100
  exec.io.tr_pulse_clear(i)
  exec.io.tr(i, 0)
end

impl('INIT.TR', function(ss, _es, cs)
  local v = cs:pop() - 1
  if v >= 0 and v < st.TR_COUNT then tr_init(ss, v) end
end)

impl('INIT.TR.ALL', function(ss, _es, _cs)
  for i = 0, st.TR_COUNT - 1 do tr_init(ss, i) end
end)

--- reset the variables only, leaving patterns and scripts alone
impl('INIT.DATA', function(ss, _es, _cs)
  local fresh = st.SceneState.new(0)
  ss.variables = fresh.variables
  update_scales(ss)
  exec.io.update_adc(1)
  exec.io.vars_updated()
  exec.io.metro_updated()
end)

--- reset the clock: clears delays, zeroes TIME, restarts LAST and EVERY
impl('INIT.TIME', function(ss, _es, _cs)
  exec.clear_delays(ss)
  ss.variables.time = 0
  local ticks = exec.io.get_ticks()
  for i = 0, st.EDITABLE_SCRIPT_COUNT - 1 do
    ss.scripts[i].last_time = ticks
  end
  for s = 0, st.TOTAL_SCRIPT_COUNT - 1 do
    for line = 0, st.SCRIPT_MAX_COMMANDS - 1 do
      local e = ss.scripts[s].every[line]
      if e.mod == 0 then e.mod = 1 end
      e.count = 0
    end
  end
end)

-- CHAOS -------------------------------------------------------------------------
-- These read and write a generator that lives outside the scene, so INIT does
-- not reset them -- matching the C, where chaos_state is a file-scope global.

impl('CHAOS',
  function(_ss, _es, cs) cs:push(chaos.get_val()) end,
  function(_ss, _es, cs) chaos.set_val(cs:pop()) end)

impl('CHAOS.R',
  function(_ss, _es, cs) cs:push(chaos.get_r()) end,
  function(_ss, _es, cs) chaos.set_r(cs:pop()) end)

impl('CHAOS.ALG',
  function(_ss, _es, cs) cs:push(chaos.get_alg()) end,
  function(_ss, _es, cs) chaos.set_alg(cs:pop()) end)
