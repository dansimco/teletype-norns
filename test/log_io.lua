-- test/log_io.lua
--
-- An io backend that records every call in the same textual form as the C
-- oracle's iolog (tools/oracle/oracle.c). Comparing those strings is how the
-- output side gets tested headlessly: it proves CV/TR ops call the right io
-- functions with the right arguments, and that indices 5..20 produce exactly
-- the i2c packets a hardware Teletype would put on the bus.

local L = {}

L.log = {}
L.ticks = 0

function L.reset() L.log = {} end
function L.text() return table.concat(L.log, ' ') end

local function put(fmt, ...) L.log[#L.log + 1] = fmt:format(...) end

function L.get_ticks() return L.ticks end

function L.metro_updated() put('metro_updated') end
function L.metro_reset() put('metro_reset') end
function L.tr(i, v) put('tr(%d,%d)', i, v) end
function L.tr_pulse(i, t) put('tr_pulse(%d,%d)', i, t) end
function L.tr_pulse_clear(i) put('tr_pulse_clear(%d)', i) end
function L.tr_pulse_time(i, t) put('tr_pulse_time(%d,%d)', i, t) end
function L.cv(i, v, s) put('cv(%d,%d,%d)', i, v, s) end
function L.cv_slew(i, v) put('cv_slew(%d,%d)', i, v) end
function L.cv_off(i, v) put('cv_off(%d,%d)', i, v) end
function L.get_cv(i) put('get_cv(%d)', i); return 0 end
function L.cv_cal(n, b, m) put('cv_cal(%d,%d,%d)', n, b, m) end
function L.update_adc(f) put('update_adc(%d)', f) end
function L.has_delays(b) put('has_delays(%d)', b and 1 or 0) end
function L.has_stack(b) put('has_stack(%d)', b and 1 or 0) end

function L.ii_tx(addr, data)
  local parts = { tostring(addr), tostring(#data) }
  for _, byte in ipairs(data) do parts[#parts + 1] = tostring(byte & 0xff) end
  put('ii_tx(%s)', table.concat(parts, ','))
end

function L.ii_rx(addr, len)
  put('ii_rx(%d,%d)', addr, len)
  local d = {}
  for i = 1, len do d[i] = 0 end
  return d
end

function L.scene(i, g, p) put('scene(%d,%d,%d)', i, g, p) end
function L.pattern_updated() put('pattern_updated') end
function L.vars_updated() end
function L.kill() put('kill') end
function L.mute() put('mute') end
function L.get_input_state(n) put('input_state(%d)', n); return false end
function L.save_calibration() end
function L.grid_key_press(x, y, z) put('grid_key(%d,%d,%d)', x, y, z) end
function L.device_flip() put('device_flip') end
function L.set_live_submode(s) put('live_submode(%d)', s) end
function L.select_dash_screen(s) put('dash_screen(%d)', s) end
function L.print_dashboard_value(i, v) put('dash_set(%d,%d)', i, v) end
function L.get_dashboard_value(i) put('dash_get(%d)', i); return 0 end
function L.reset_midi_counter() put('reset_midi_counter') end

return L
