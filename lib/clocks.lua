-- clocks.lua -- the three timers that make a scene move.
--
-- Teletype's hardware runs several soft timers; three of them matter here:
--
--   tick     10ms, drains the 64-slot delay queue and steps the turtle. This
--            is RATE_CLOCK in module/main.c, and it is why delay resolution is
--            10ms rather than 1ms.
--   metro    the M script, re-armed whenever M or M.ACT changes. Floor is 25ms
--            (METRO_MIN_MS), or 2ms if the scene used M! instead.
--   midi     25ms, dispatches queued MIDI events to their bound scripts,
--            matching midiScriptTimer in module/main.c.
--
-- TR pulse timing is deliberately absent: pulse width lives on the crow, so
-- there is no norns-side timer for it. The exception is a TR routed only to
-- MIDI, whose note-off is scheduled here as a one-shot.

local exec = require 'exec'
local st = require 'state'

local M = {}

M.TICK_MS = 10
M.MIDI_POLL_MS = 25

M.ss = nil          -- the scene being run
M.io = nil          -- the io backend, for advancing its millisecond clock

local tick_metro, metro_metro, midi_metro

--- called after each metro script run, so the UI can redraw
M.on_metro_fire = nil
M.on_tick = nil

-- ------------------------------------------------------------------- tick

local function do_tick()
  if not M.ss then return end
  -- the io layer's clock is what TIME and LAST read, so advance it in step
  M.io.ticks = M.io.ticks + M.TICK_MS
  exec.tick(M.ss, M.TICK_MS)
  if M.on_tick then M.on_tick() end
end

-- ------------------------------------------------------------------ metro

local function do_metro()
  if not M.ss then return end
  if M.ss.variables.m_act == 0 then return end
  exec.run_script(M.ss, st.METRO_SCRIPT)
  if M.on_metro_fire then M.on_metro_fire() end
end

--- re-arm the metro from the scene's M and M.ACT.
-- Called from the io layer's metro_updated hook, so any op that changes M
-- retimes the metro immediately, exactly as tele_metro_updated does.
function M.update_metro()
  if not metro_metro or not M.ss then return end
  local v = M.ss.variables
  if v.m_act == 0 then
    metro_metro:stop()
    return
  end
  -- M is clamped by the op itself (25ms, or 2ms via M!); guard anyway so a
  -- scene loaded from a file cannot ask for a 0ms metro
  local ms = v.m
  if ms < st.METRO_MIN_UNSUPPORTED_MS then ms = st.METRO_MIN_UNSUPPORTED_MS end
  metro_metro.time = ms / 1000
  metro_metro:start()
end

--- restart the metro's phase without firing it. M.RESET
function M.reset_metro()
  if not metro_metro then return end
  metro_metro:stop()
  M.update_metro()
end

-- ------------------------------------------------------------------- midi

--- drain the queued MIDI events into their bound scripts.
-- Teletype collects events between polls and then runs the bound script once
-- per batch, with the event arrays readable through MI.N / MI.V and friends.
local function do_midi()
  if not M.ss then return end
  local m = M.ss.midi

  if m.on_count > 0 and m.on_script >= 0 then
    exec.run_script(M.ss, m.on_script)
    m.on_count = 0
  end
  if m.off_count > 0 and m.off_script >= 0 then
    exec.run_script(M.ss, m.off_script)
    m.off_count = 0
  end
  if m.cc_count > 0 and m.cc_script >= 0 then
    exec.run_script(M.ss, m.cc_script)
    m.cc_count = 0
  end
end

-- ------------------------------------------------------------------ set up

--- start all three timers. `metro_lib` is norns' `metro`.
function M.start(metro_lib, ss, io_impl)
  M.ss = ss
  M.io = io_impl

  tick_metro = metro_lib.init(do_tick, M.TICK_MS / 1000, -1)
  tick_metro:start()

  -- started stopped; update_metro arms it from the scene
  metro_metro = metro_lib.init(do_metro, 1, -1)

  midi_metro = metro_lib.init(do_midi, M.MIDI_POLL_MS / 1000, -1)
  midi_metro:start()

  M.update_metro()
end

function M.stop()
  if tick_metro then tick_metro:stop() end
  if metro_metro then metro_metro:stop() end
  if midi_metro then midi_metro:stop() end
end

--- swap in a different scene (loading a new file) without restarting timers
function M.set_scene(ss)
  M.ss = ss
  M.update_metro()
end

return M
