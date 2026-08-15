-- ops/hardware.lua -- port of teletype/src/ops/hardware.c
--
-- CV, TR, and the front-panel inputs. This is the file Phase 4 hangs crow off:
-- every output op ends in a call through exec.io (the teletype_io.h surface),
-- and nothing here knows what a crow is.
--
-- One structural detail worth knowing: teletype already treats CV/TR indices
-- 5..20 as an Ansible expander reached over i2c, four outputs per device at an
-- address stride of two. We keep exactly that, so a scene written for a
-- hardware Teletype driving an Ansible works unchanged -- lib/io/ansible_io
-- just routes the same packets through crow's ii instead of the module's bus.

local exec = require 'exec'
local helpers = require 'helpers'
local registry = require 'ops.registry'
local scale = require 'scale'
local st = require 'state'

local impl = registry.impl

-- libavr32/src/ii.h
local II_ANSIBLE_ADDR = 0x20
local II_GET = 128
local II = {
  TR = 1, TR_TOG = 2, TR_PULSE = 3, TR_TIME = 4, TR_POL = 5,
  CV = 6, CV_SLEW = 7, CV_OFF = 8, CV_SET = 9,
  INPUT = 10,
}

--- address of the Ansible holding output `a` (0-based, already past the local
--- four). hardware.c:129 -- four outputs per device, stride two.
local function ansible_addr(a, base)
  return II_ANSIBLE_ADDR + (((a - (base or 4)) >> 2) << 1)
end

local function ansible_port(a) return a & 0x3 end

--- read a 16-bit value back from an Ansible
local function ii_get16(cmd, a)
  local addr = ansible_addr(a)
  exec.io.ii_tx(addr, { cmd | II_GET, ansible_port(a) })
  local d = exec.io.ii_rx(addr, 2)
  return ((d[1] or 0) << 8) + (d[2] or 0)
end

local function ii_get8(cmd, a)
  local addr = ansible_addr(a)
  exec.io.ii_tx(addr, { cmd | II_GET, ansible_port(a) })
  local d = exec.io.ii_rx(addr, 1)
  return d[1] or 0
end

local function ii_set16(cmd, a, b)
  exec.io.ii_tx(ansible_addr(a),
    { cmd, ansible_port(a), (b >> 8) & 0xff, b & 0xff })
end

local function ii_set8(cmd, a, b)
  exec.io.ii_tx(ansible_addr(a), { cmd, ansible_port(a), b })
end

--- shared shape for the CV/TR ops: index 1..4 local, 5..20 over i2c, else 0.
-- `local_get`/`local_set` handle the first four; the rest is boilerplate.
local function routed(name, ii_cmd, width, local_get, local_set)
  local get16 = (width == 16)
  impl(name,
    function(ss, _es, cs)
      local a = cs:pop() - 1
      if a < 0 then cs:push(0)
      elseif a < 4 then cs:push(local_get(ss, a))
      elseif a < 20 then
        cs:push(get16 and ii_get16(ii_cmd, a) or ii_get8(ii_cmd, a))
      else cs:push(0) end
    end,
    local_set and function(ss, _es, cs)
      local a = cs:pop() - 1
      local b = cs:pop()
      if a < 0 then return
      elseif a < 4 then local_set(ss, a, b)
      elseif a < 20 then
        if get16 then ii_set16(ii_cmd, a, b) else ii_set8(ii_cmd, a, b) end
      end
    end or nil)
end

-- CV --------------------------------------------------------------------------

routed('CV', II.CV, 16,
  function(ss, a) return ss.variables.cv[a] end,
  function(ss, a, b)
    b = helpers.normalise_value(0, 16383, 0, b)
    ss.variables.cv[a] = b
    exec.io.cv(a, b, 1)          -- slew enabled
  end)

routed('CV.SLEW', II.CV_SLEW, 16,
  function(ss, a) return ss.variables.cv_slew[a] end,
  function(ss, a, b)
    b = helpers.normalise_value(1, 32767, 0, b)   -- minimum slew is 1ms
    ss.variables.cv_slew[a] = b
    exec.io.cv_slew(a, b)
  end)

routed('CV.OFF', II.CV_OFF, 16,
  function(ss, a) return ss.variables.cv_off[a] end,
  function(ss, a, b)
    -- not clamped, unlike CV: an offset may legitimately be negative
    ss.variables.cv_off[a] = b
    exec.io.cv_off(a, b)
    exec.io.cv(a, ss.variables.cv[a], 1)   -- re-apply so it takes effect now
  end)

--- CV.SET writes without slewing. hardware.c:504
impl('CV.SET', function(ss, _es, cs)
  local a = cs:pop() - 1
  local b = cs:pop()
  if b < 0 then b = 0 elseif b > 16383 then b = 16383 end
  if a < 0 then return
  elseif a < 4 then
    ss.variables.cv[a] = b
    exec.io.cv(a, b, 0)          -- slew bypassed
  elseif a < 20 then
    ii_set16(II.CV_SET, a, b)
  end
end)

--- CV.GET reads the value actually being output, after slew and offset.
impl('CV.GET', function(_ss, _es, cs)
  local i = (cs:pop() - 1) & 0xff
  cs:push(i < 4 and exec.io.get_cv(i) or 0)
end)

-- TR --------------------------------------------------------------------------

routed('TR', II.TR, 8,
  function(ss, a) return ss.variables.tr[a] end,
  function(ss, a, b)
    ss.variables.tr[a] = (b ~= 0) and 1 or 0
    exec.io.tr(a, b)
  end)

routed('TR.POL', II.TR_POL, 8,
  function(ss, a) return ss.variables.tr_pol[a] end,
  function(ss, a, b)
    -- note: no io call. polarity only affects the next pulse.
    ss.variables.tr_pol[a] = (b > 0) and 1 or 0
  end)

routed('TR.TIME', II.TR_TIME, 16,
  function(ss, a) return ss.variables.tr_time[a] end,
  function(ss, a, b)
    if b < 0 then b = 0 end
    ss.variables.tr_time[a] = b
    exec.io.tr_pulse_time(a, b)
  end)

impl('TR.TOG', function(ss, _es, cs)
  local a = cs:pop() - 1
  if a < 0 then return
  elseif a < 4 then
    ss.variables.tr[a] = (ss.variables.tr[a] ~= 0) and 0 or 1
    exec.io.tr(a, ss.variables.tr[a])
  elseif a < 20 then
    exec.io.ii_tx(ansible_addr(a), { II.TR_TOG, ansible_port(a) })
  end
end)

impl('TR.PULSE', function(ss, _es, cs)
  local a = cs:pop() - 1
  if a < 0 then return
  elseif a < 4 then
    local time = ss.variables.tr_time[a]
    if time <= 0 then return end        -- a zero pulse width does nothing
    -- the output goes to its *polarity* level, and tr_pulse schedules the
    -- return to rest; with TR.POL 0 that means a downward pulse
    ss.variables.tr[a] = ss.variables.tr_pol[a]
    exec.io.tr(a, ss.variables.tr[a])
    exec.io.tr_pulse(a, time)
  elseif a < 20 then
    exec.io.ii_tx(ansible_addr(a), { II.TR_PULSE, ansible_port(a) })
  end
end)

-- calibration -------------------------------------------------------------------

--- derive a gain/offset from measured 1V and 3V readings. hardware.c:249
impl('CV.CAL', function(_ss, _es, cs)
  local n = cs:pop() - 1
  local vv1v = cs:pop()
  local vv3v = cs:pop()
  if n < 0 or n > 3 then return end
  if vv3v == vv1v then return end       -- would divide by zero
  local s = (4915.0 - 1638.0) / ((vv3v - vv1v) * 1.6383)
  local offset = 4915.0 / s - vv3v * 1.6383
  -- the C casts double to int32_t, which truncates toward zero; lua's // and
  -- math.floor round toward -inf, which differs for a negative offset
  local function trunc(x)
    return math.tointeger(x >= 0 and math.floor(x) or -math.floor(-x)) or 0
  end
  exec.io.cv_cal(n, trunc(offset * (1 << 15)), trunc(s * (1 << 15)))
end)

impl('CV.CAL.RESET', function(_ss, _es, cs)
  local n = cs:pop() - 1
  if n < 0 or n > 3 then return end
  exec.io.cv_cal(n, 0, 1)
end)

-- inputs ---------------------------------------------------------------------
-- IN and PARAM are the CV input jack and the panel knob. norns has neither, so
-- they read whatever was last written to the scene -- see docs/differences.md.

impl('IN', function(ss, _es, cs)
  exec.io.update_adc(0)
  cs:push(scale.get(ss.variables.in_scale, ss.variables['in']))
end)

impl('IN.SCALE', function(ss, _es, cs)
  local min, max = cs:pop(), cs:pop()
  ss.variables.in_range = { min, max }
  ss.variables.in_scale = scale.init(ss.cal.i_min, ss.cal.i_max, min, max)
end)

impl('PARAM', function(ss, _es, cs)
  exec.io.update_adc(0)
  cs:push(scale.get(ss.variables.param_scale, ss.variables.param))
end)

impl('PARAM.SCALE', function(ss, _es, cs)
  local min, max = cs:pop(), cs:pop()
  ss.variables.param_range = { min, max }
  ss.variables.param_scale = scale.init(ss.cal.p_min, ss.cal.p_max, min, max)
end)

-- calibration of those inputs: MIN/MAX capture the current reading as the
-- corresponding end of the range, and return it
local function cal_capture(name, cal_field, var_field, update)
  impl(name, function(ss, _es, cs)
    ss.cal[cal_field] = ss.variables[var_field]
    update(ss)
    cs:push(ss.variables[var_field])
  end)
end

local function update_in(ss)
  ss.variables.in_scale = scale.init(ss.cal.i_min, ss.cal.i_max,
    ss.variables.in_range[1], ss.variables.in_range[2])
end

local function update_param(ss)
  ss.variables.param_scale = scale.init(ss.cal.p_min, ss.cal.p_max,
    ss.variables.param_range[1], ss.variables.param_range[2])
end

cal_capture('IN.CAL.MIN', 'i_min', 'in', update_in)
cal_capture('IN.CAL.MAX', 'i_max', 'in', update_in)
cal_capture('PARAM.CAL.MIN', 'p_min', 'param', update_param)
cal_capture('PARAM.CAL.MAX', 'p_max', 'param', update_param)

impl('IN.CAL.RESET', function(ss, _es, _cs)
  ss.cal.i_min, ss.cal.i_max = 0, 16383
  update_in(ss)
end)

impl('PARAM.CAL.RESET', function(ss, _es, _cs)
  ss.cal.p_min, ss.cal.p_max = 0, 16383
  update_param(ss)
end)

-- trigger inputs ---------------------------------------------------------------

impl('MUTE',
  function(ss, _es, cs)
    local a = cs:pop() - 1
    if a >= 0 and a < st.TRIGGER_INPUTS then
      cs:push(ss.variables.mutes[a] and 1 or 0)
    else
      cs:push(0)
    end
  end,
  function(ss, _es, cs)
    local a = cs:pop() - 1
    local b = cs:pop() > 0
    -- ss_set_mute notifies the UI so it can redraw the mute indicators
    if a >= 0 and a < st.TRIGGER_INPUTS then
      ss.variables.mutes[a] = b
      exec.io.mute()
    end
  end)

impl('STATE', function(_ss, _es, cs)
  local a = cs:pop() - 1
  if a < 0 then cs:push(0)
  elseif a < 8 then
    cs:push(exec.io.get_input_state(a) and 1 or 0)
  elseif a < 24 then
    -- the ansible inputs start at index 8, not 4
    local addr = ansible_addr(a, 8)
    exec.io.ii_tx(addr, { II.INPUT | II_GET, ansible_port(a) })
    local d = exec.io.ii_rx(addr, 1)
    cs:push(d[1] or 0)
  else cs:push(0) end
end)

-- screen / dashboard -----------------------------------------------------------
-- these drive teletype's live-mode display. the norns UI implements the same
-- notions in lib/ui, so they stay wired to the io layer rather than stubbed.

impl('DEVICE.FLIP', function(_ss, _es, _cs) exec.io.device_flip() end)

local SUB_MODE = { OFF = 0, VARS = 1, GRID = 2, FULLGRID = 3, DASH = 4 }

impl('LIVE.OFF', function(_ss, _es, _cs) exec.io.set_live_submode(SUB_MODE.OFF) end)
impl('LIVE.GRID', function(_ss, _es, _cs) exec.io.set_live_submode(SUB_MODE.GRID) end)
impl('LIVE.VARS', function(_ss, _es, _cs) exec.io.set_live_submode(SUB_MODE.VARS) end)
impl('LIVE.DASH', function(_ss, _es, cs)
  exec.io.select_dash_screen(cs:pop() - 1)
end)

impl('PRINT',
  function(_ss, _es, cs) cs:push(exec.io.get_dashboard_value(cs:pop() - 1)) end,
  function(_ss, _es, cs)
    local index = cs:pop()
    exec.io.print_dashboard_value(index - 1, cs:pop())
  end)

-- aliases ------------------------------------------------------------------------

local function alias(name, target)
  local t = registry.ops[registry.by_name[target]]
  impl(name, t.get, t.set)
end

alias('PRM', 'PARAM')
alias('TR.P', 'TR.PULSE')
alias('LIVE.O', 'LIVE.OFF')
alias('LIVE.D', 'LIVE.DASH')
alias('LIVE.G', 'LIVE.GRID')
alias('LIVE.V', 'LIVE.VARS')
alias('PRT', 'PRINT')
