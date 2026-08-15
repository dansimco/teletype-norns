-- io/routing.lua -- the device-side implementation of teletype_io.h.
--
-- The language core calls exactly the ~35 functions in lib/io/null_io.lua and
-- knows nothing else about the outside world. This module is the other
-- implementation: it fans each call out to crow, to an Ansible over crow's
-- i2c, and to MIDI devices, according to the params.
--
-- It also intercepts the raw i2c packets the core builds. Teletype addresses
-- CV/TR 5..20 and the whole Ansible op family as i2c writes, so rather than
-- special-casing those ops we let them build their packets as the hardware
-- would and decode them back into crow ii calls here. That keeps the core
-- byte-identical to the reference and puts every device-specific decision in
-- one file.

local ansible_io = require 'io.ansible_io'
local crow_io = require 'io.crow_io'
local midi_io = require 'io.midi_io'

local M = {}

M.crow = crow_io
M.midi = midi_io
M.ansible = ansible_io

--- millisecond clock. set from the script's metro.
M.ticks = 0
function M.get_ticks() return M.ticks end

--- hooks the UI installs to hear about state changes
M.on_metro_change = nil
M.on_pattern_change = nil
M.on_vars_change = nil
M.on_kill = nil
M.on_activity = nil

-- ------------------------------------------------------------------ outputs

local CV_NAMES = { [0] = 'cv1', 'cv2', 'cv3', 'cv4' }
local TR_NAMES = { [0] = 'trA', 'trB', 'trC', 'trD' }

-- The hardware knows it is slewing because it runs the ramp itself and reads
-- the answer off its DAC loop (module/main.c:220). crow resolves slews
-- on-board, so track when each ramp is due to land and answer from that. The
-- default of 1ms matches the cv_slew the scene state initialises to.
M.slew_ms = { [0] = 1, 1, 1, 1 }
M.slew_until = { [0] = 0, 0, 0, 0 }

--- is any output still ramping? drives the LIVE mode slew indicator.
function M.slewing()
  for i = 0, 3 do
    if M.slew_until[i] > M.ticks then return true end
  end
  return false
end

function M.cv(i, v, slew)
  if slew ~= 0 then M.slew_until[i] = M.ticks + (M.slew_ms[i] or 1) end
  crow_io.cv(i, v, slew)
  midi_io.cv(CV_NAMES[i], v)
end

function M.cv_slew(i, v)
  M.slew_ms[i] = v
  crow_io.cv_slew(i, v)
end
function M.cv_off(i, v) crow_io.cv_off(i, v) end
function M.get_cv(_i) return 0 end          -- crow cannot be read back
function M.cv_cal(_n, _b, _m) end           -- calibration is a module concern

function M.tr(i, v)
  crow_io.tr(i, v)
  midi_io.tr(TR_NAMES[i], v)
end

function M.tr_pulse(i, time)
  crow_io.tr_pulse(i, time)
  -- MIDI has no pulse: raise the gate now and let the core's pulse timer
  -- bring it down through tr() again
  midi_io.tr(TR_NAMES[i], 1)
end

function M.tr_pulse_time(i, time) crow_io.tr_pulse_time(i, time) end
function M.tr_pulse_clear(_i) end
function M.tr_pol(i, p) crow_io.tr_pol(i, p) end

-- ---------------------------------------------------------------------- i2c
-- Decode the packets the core builds. crow exposes each Ansible app as its own
-- ii module (ii.ansible, ii.kria, ii.meadowphysics, ii.levels), so the address
-- selects the module and the first byte selects the command. Bit 7 marks a
-- read, which on crow is asynchronous.

local II_GET = 128

--- the last read request, so the matching ii_rx knows what to answer with
local pending_read = nil

function M.ii_tx(addr, data)
  local device = ansible_io.device_for(addr)
  local cmd = data[1] or 0
  local is_read = (cmd & II_GET) ~= 0
  local entry = device and device.commands[cmd & 0x7f]

  -- Writes go out raw when we can: byte-exact, no name or unit mapping to get
  -- wrong, and it covers the families crow has no module for.
  if not is_read and ansible_io.raw_send and ansible_io.prefer_raw then
    ansible_io.raw_send(addr, data)
    return
  end

  -- no crow module for this address, or no such command in it
  if not entry then
    if ansible_io.raw_send then
      ansible_io.raw_send(addr, data)
    else
      ansible_io.note_unmapped(addr, data)
    end
    return
  end

  if is_read then
    if not entry.read then
      -- the command exists but crow exposes no getter for it (kria page, cue,
      -- direction...). record it so the UI can say the read is unavailable
      -- rather than quietly returning a stale zero.
      ansible_io.note_unmapped(addr, data)
      pending_read = nil
      return
    end
    pending_read = {
      module = device.module,
      entry = entry,
      args = ansible_io.decode_args(entry.read, data),
    }
    return
  end

  if not entry.args then
    -- read-only command (ansible input, the per-app cv readers)
    ansible_io.note_unmapped(addr, data)
    return
  end

  ansible_io.send(M.crow_ii, device.module, entry.name,
    ansible_io.decode_args(entry.args, data))
end

function M.ii_rx(_addr, len)
  local d = {}
  for i = 1, len do d[i] = 0 end
  if not pending_read then return d end

  local value = ansible_io.read(M.crow_ii, pending_read.module,
    pending_read.entry, pending_read.args)
  pending_read = nil

  if len == 2 then
    d[1] = (value >> 8) & 0xff
    d[2] = value & 0xff
  else
    d[1] = value & 0xff
  end
  return d
end

-- ------------------------------------------------------- state notifications

function M.metro_updated() if M.on_metro_change then M.on_metro_change() end end
function M.metro_reset() if M.on_metro_change then M.on_metro_change(true) end end
function M.pattern_updated() if M.on_pattern_change then M.on_pattern_change() end end
function M.vars_updated() if M.on_vars_change then M.on_vars_change() end end

function M.kill()
  crow_io.reset()
  midi_io.all_off()
  if M.on_kill then M.on_kill() end
end

-- these three are the C's `dirty |= D_ACTIVITY`: the core telling the UI that
-- an indicator changed. Nothing is drawn here -- the strip reads the state
-- itself -- but the screen has to be told to look again.
function M.mute() if M.on_activity then M.on_activity() end end
function M.has_delays(_b) if M.on_activity then M.on_activity() end end
function M.has_stack(_b) if M.on_activity then M.on_activity() end end
function M.update_adc(_force) end
function M.get_input_state(_n) return false end
function M.save_calibration() end
function M.scene(_i, _g, _p) end
function M.device_flip() end
function M.grid_key_press(_x, _y, _z) end
function M.reset_midi_counter() end

-- the live-mode submodes and dashboard are UI concerns; the script installs
-- real handlers over these
function M.set_live_submode(_s) end
function M.select_dash_screen(_s) end
function M.print_dashboard_value(_i, _v) end
function M.get_dashboard_value(_i) return 0 end

return M
