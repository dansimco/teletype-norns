-- ops/midi_in.lua -- port of teletype/src/ops/midi.c
--
-- Incoming MIDI. `MI.$` binds an event type to a script; the rest read the
-- events that arrived since that script was triggered.
--
-- The per-event readers are indexed by `I`, not by an argument: a script bound
-- to note-on is expected to loop with `L 1 MI.NL` and read `MI.N` each time.
-- That is why they take no parameters but still return different values.
--
-- On norns these are fed from a real MIDI device; lib/io drives the same
-- scene_midi state the C fills from USB.

local exec = require 'exec'
local registry = require 'ops.registry'
local st = require 'state'
local T = require 'tables'

local impl = registry.impl

-- MI.$ event selectors
local EVENT_FIELDS = {
  [1] = 'on_script', [2] = 'off_script', [3] = 'cc_script',
  [4] = 'clk_script', [5] = 'start_script', [6] = 'stop_script',
  [7] = 'continue_script',
}

impl('MI.$',
  function(ss, _es, cs)
    local event = cs:pop() & 0xffff
    local script = -1
    if event == 0 then
      -- event 0 means "all"; it only reports a script if every binding agrees
      local m = ss.midi
      script = m.on_script
      if script ~= m.off_script or script ~= m.cc_script
          or script ~= m.clk_script or script ~= m.start_script
          or script ~= m.stop_script or script ~= m.continue_script then
        script = -1
      end
    elseif EVENT_FIELDS[event] then
      script = ss.midi[EVENT_FIELDS[event]]
    end
    cs:push(script == -1 and -1 or script + 1)
  end,
  function(ss, _es, cs)
    local event = cs:pop() & 0xffff
    local script = cs:pop() - 1
    if script < 0 or script > st.INIT_SCRIPT then script = -1 end
    local m = ss.midi
    if event == 0 then
      m.on_script, m.off_script, m.cc_script = script, script, script
      m.clk_script, m.start_script = script, script
      m.stop_script, m.continue_script = script, script
      m.on_count, m.off_count, m.cc_count = 0, 0, 0
    elseif event == 1 then
      m.on_script = script; m.on_count = 0
    elseif event == 2 then
      m.off_script = script; m.off_count = 0
    elseif event == 3 then
      m.cc_script = script; m.cc_count = 0
    elseif EVENT_FIELDS[event] then
      m[EVENT_FIELDS[event]] = script
    end
  end)

-- last-event readers -------------------------------------------------------------
-- These report whatever arrived most recently, regardless of which script is
-- running. Velocity and CC are scaled by 129 to span 0..16383 from 0..127.

local function last(name, fn)
  impl(name, function(ss, _es, cs) cs:push(fn(ss.midi)) end)
end

last('MI.LE', function(m) return m.last_event_type end)
last('MI.LN', function(m) return m.last_note end)
last('MI.LNV', function(m) return T.table_n[m.last_note] end)
last('MI.LV', function(m) return m.last_velocity end)
last('MI.LVV', function(m) return m.last_velocity * 129 end)
last('MI.LO', function(m) return m.last_note end)
last('MI.LC', function(m) return m.last_controller end)
last('MI.LCC', function(m) return m.last_cc end)
last('MI.LCCV', function(m) return m.last_cc * 129 end)
last('MI.LCH', function(m) return m.last_channel + 1 end)

-- queued-event readers -------------------------------------------------------------
-- Indexed by I, 1-based, bounded by the matching count.

--- read entry I of `array`, valid while I is within `count_field`
local function indexed(name, count_field, fn)
  impl(name, function(ss, es, cs)
    local i = es:vars().i
    local m = ss.midi
    if i < 1 or i > m[count_field] then cs:push(0) return end
    cs:push(fn(m, i - 1))
  end)
end

last('MI.NL', function(m) return m.on_count end)
indexed('MI.N', 'on_count', function(m, i) return m.note_on[i] end)
indexed('MI.NV', 'on_count', function(m, i) return T.table_n[m.note_on[i]] end)
indexed('MI.V', 'on_count', function(m, i) return m.note_vel[i] end)
indexed('MI.VV', 'on_count', function(m, i) return m.note_vel[i] * 129 end)
indexed('MI.NCH', 'on_count', function(m, i) return m.on_channel[i] + 1 end)

last('MI.OL', function(m) return m.off_count end)
indexed('MI.O', 'off_count', function(m, i) return m.note_off[i] end)
indexed('MI.OCH', 'off_count', function(m, i) return m.off_channel[i] + 1 end)

last('MI.CL', function(m) return m.cc_count end)
indexed('MI.C', 'cc_count', function(m, i) return m.cn[i] end)
indexed('MI.CC', 'cc_count', function(m, i) return m.cc[i] end)
indexed('MI.CCV', 'cc_count', function(m, i) return m.cc[i] * 129 end)
indexed('MI.CCH', 'cc_count', function(m, i) return m.cc_channel[i] + 1 end)

-- clock ------------------------------------------------------------------------------

impl('MI.CLKD',
  function(ss, _es, cs) cs:push(ss.midi.clock_div) end,
  function(ss, _es, cs)
    local clock_div = cs:pop()
    if clock_div < 1 or clock_div > 24 then return end
    ss.midi.clock_div = clock_div
    exec.io.reset_midi_counter()
  end)

impl('MI.CLKR', function(_ss, _es, _cs) exec.io.reset_midi_counter() end)
