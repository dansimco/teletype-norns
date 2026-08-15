-- scale.lua -- fixed-point linear scaling, port of teletype/src/scale.h
--
-- Q16.15: the gain is stored as a 32-bit integer with 15 fractional bits, so
-- IN and PARAM can be rescaled without floating point. The rounding in
-- FROM_Q15 (add a half, then shift) is load-bearing -- IN.SCALE results differ
-- by one without it.

local int16 = require 'int16'

local M = {}

local function to_q15(x) return x << 15 end
local function from_q15(x) return ((x >> 14) + 1) >> 1 end

M.to_q15 = to_q15
M.from_q15 = from_q15

--- build a scale mapping [izero, imax] onto [ozero, omax]. scale.h:51
function M.init(izero, imax, ozero, omax)
  if izero == imax then imax = 1 end
  local m = to_q15(omax - ozero) // (imax - izero)
  local b = ozero - from_q15(m * izero)
  return { m = m, b = b }
end

--- apply a scale. scale.h:61 -- the result is an int16.
function M.get(s, x)
  return int16.wrap(from_q15(s.m * x) + s.b)
end

--- default calibration. scale.c:4
function M.new_cal()
  local cal = { p_min = 0, p_max = 16383, i_min = 0, i_max = 16383,
                f_min = {}, f_max = {}, cv_scale = {} }
  for i = 0, 63 do cal.f_min[i] = 0; cal.f_max[i] = 16383 end
  for j = 0, 3 do cal.cv_scale[j] = { b = 0, m = 1 } end
  return cal
end

return M
