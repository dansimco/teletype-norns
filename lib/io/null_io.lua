-- io/null_io.lua
--
-- The teletype_io.h surface as a set of no-ops. This is the seam the whole
-- port hangs on: teletype/src is portable C precisely because every hardware
-- interaction goes through these ~35 functions, and both teletype's own test
-- suite and its desktop simulator supply stub versions exactly like this one.
--
-- Keeping a null backend means the entire language core -- parser, evaluator,
-- 400+ ops -- is exercised on the dev machine with no norns, no crow and no
-- hardware. lib/io/routing.lua provides the real implementation on device.

local N = {}

-- timebase ------------------------------------------------------------------
-- ms counter behind TIME and LAST. the null backend advances only when a test
-- sets it, so delay and timing behaviour stays deterministic.
N.ticks = 0
function N.get_ticks() return N.ticks end

-- metro ---------------------------------------------------------------------
function N.metro_updated() end
function N.metro_reset() end

-- outputs -------------------------------------------------------------------
function N.tr(_i, _v) end
function N.tr_pulse(_i, _time) end
function N.tr_pulse_clear(_i) end
function N.tr_pulse_time(_i, _time) end
function N.cv(_i, _v, _slew) end
function N.cv_slew(_i, _v) end
function N.cv_off(_i, _v) end
function N.get_cv(_i) return 0 end
--- nothing ramps without hardware, so the slew indicator is never lit
function N.slewing() return false end
function N.cv_cal(_n, _b, _m) end

-- inputs --------------------------------------------------------------------
function N.update_adc(_force) end
function N.get_input_state(_n) return false end

-- i2c -----------------------------------------------------------------------
function N.ii_tx(_addr, _data) end
function N.ii_rx(_addr, _len) return {} end

-- ui / state notifications --------------------------------------------------
function N.has_delays(_b) end
function N.has_stack(_b) end
function N.pattern_updated() end
function N.vars_updated() end
function N.kill() end
function N.mute() end
function N.scene(_i, _init_grid, _init_pattern) end
function N.save_calibration() end
function N.set_live_submode(_s) end
function N.select_dash_screen(_s) end
function N.print_dashboard_value(_i, _v) end
function N.get_dashboard_value(_i) return 0 end
function N.device_flip() end
function N.grid_key_press(_x, _y, _z) end
function N.reset_midi_counter() end

return N
