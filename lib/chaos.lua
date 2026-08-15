-- chaos.lua -- port of teletype/src/chaos.c
--
-- Four chaotic generators behind the CHAOS ops. Three of them are float-based,
-- and the C uses 32-bit `float` while lua only has doubles -- so every
-- arithmetic step is rounded back through float32 with string.pack. Without
-- that the sequences diverge after a handful of iterations, since these maps
-- amplify small differences by design.
--
-- Note the state is a *global* in the C, not part of scene_state, so it
-- survives INIT and scene changes. We keep that.

local int16 = require 'int16'

local M = {}

--- round a double to the nearest float32, as a C `float` assignment would
local function f32(x)
  return (string.unpack('<f', string.pack('<f', x)))
end

--- C float-to-int conversion truncates toward zero
local function trunc(x)
  if x ~= x then return 0 end                       -- NaN
  return math.tointeger(x >= 0 and math.floor(x) or -math.floor(-x)) or 0
end

M.ALGO = { LOGISTIC = 0, CUBIC = 1, HENON = 2, CELLULAR = 3 }
local ALGO_COUNT = 4

local VALUE_MAX = 10000
local PARAM_MAX = 10000
local HENON_B = f32(0.3)
local CELL_COUNT = 8
local CELL_MAX = 0xff

local state = {
  ix = 5000, ir = 5000, alg = M.ALGO.LOGISTIC,
  fx = 0.0, fr = 0.0, fx0 = 0.0, fx1 = 0.0,
}

--- rescale the integer state/param into the float domain the current algorithm
--- expects. chaos.c:30
local function scale_values()
  if state.alg == M.ALGO.HENON then
    -- x in [-1.5, 1.5], r in [1, 1.4]
    state.fx = f32(f32(state.ix / f32(VALUE_MAX)) * f32(1.5))
    state.fr = f32(1.0 + f32(f32(state.ir / f32(PARAM_MAX)) * f32(0.4)))
    if state.fr < 1.0 then state.fr = 1.0 end
    if state.fr > 1.4 then state.fr = f32(1.4) end
  elseif state.alg == M.ALGO.CELLULAR then
    -- both state and rule are 8-bit here
    if state.ix > CELL_MAX then state.ix = CELL_MAX end
    if state.ix < 0 then state.ix = 0 end
    if state.ir > 0xff then state.ir = 0xff end
    if state.ir < 0 then state.ir = 0 end
  else
    -- cubic / logistic: x in [-1, 1], r in [3.0, 4)
    state.fx = f32(state.ix / f32(VALUE_MAX))
    state.fr = f32(f32(f32(state.ir / f32(PARAM_MAX)) * f32(0.9999)) + 3.0)
  end
end

function M.init() scale_values() end

function M.set_val(v) state.ix = v; scale_values() end
function M.get_r() return state.ir end
function M.set_r(r) state.ir = r; scale_values() end
function M.get_alg() return state.alg end

function M.set_alg(a)
  if a < 0 then a = 0 end
  if a >= ALGO_COUNT then a = ALGO_COUNT - 1 end
  state.alg = a
  scale_values()
end

-- the maps ---------------------------------------------------------------------

local function logistic()
  if state.fx < 0.0 then state.fx = 0.0 end
  state.fx = f32(f32(state.fx * state.fr) * f32(1.0 - state.fx))
  state.ix = int16.wrap(trunc(f32(state.fx * f32(VALUE_MAX))))
  return state.ix
end

local function cubic()
  local x3 = f32(f32(state.fx * state.fx) * state.fx)
  state.fx = f32(f32(state.fr * x3) + f32(state.fx * f32(1.0 - state.fr)))
  state.ix = int16.wrap(trunc(f32(state.fx * f32(VALUE_MAX))))
  return state.ix
end

local function henon()
  local x0_2 = f32(state.fx0 * state.fx0)
  local x = f32(f32(1.0 - f32(x0_2 * state.fr)) + f32(HENON_B * state.fx1))
  -- reflect at the bounds rather than letting it blow up
  while x < -1.5 do x = f32(-1.5 - x) end
  while x > 1.5 do x = f32(1.5 - x) end
  state.fx1 = state.fx0
  state.fx0 = state.fx
  state.fx = x
  state.ix = int16.wrap(trunc(f32(f32(x / f32(1.5)) * f32(VALUE_MAX))))
  return state.ix
end

--- 1-D binary cellular automaton; `ir` is the 8-bit rule. chaos.c:90
local function cellular()
  local x = state.ix & 0xff
  local y = 0
  for i = 0, CELL_COUNT - 1 do
    local code = 0
    -- bit 0 of the code is the right-hand neighbour, wrapping
    if i == 0 then
      if (x & 0x80) ~= 0 then code = code | 1 end
    else
      if (x & (1 << (i - 1))) ~= 0 then code = code | 1 end
    end
    -- bit 2 is the left-hand neighbour, wrapping
    if i == CELL_COUNT - 1 then
      if (x & 1) ~= 0 then code = code | 4 end
    else
      if (x & (1 << (i + 1))) ~= 0 then code = code | 4 end
    end
    -- bit 1 is this cell's current value
    if (x & (1 << i)) ~= 0 then code = code | 2 end
    if (state.ir & (1 << code)) ~= 0 then y = y | (1 << i) end
  end
  state.ix = y
  return state.ix
end

function M.get_val()
  if state.alg == M.ALGO.LOGISTIC then return logistic() end
  if state.alg == M.ALGO.CUBIC then return cubic() end
  if state.alg == M.ALGO.HENON then return henon() end
  if state.alg == M.ALGO.CELLULAR then return cellular() end
  return 0
end

scale_values()

return M
