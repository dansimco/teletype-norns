-- turtle.lua -- port of teletype/src/turtle.c
--
-- The turtle walks the pattern data as a 4x64 grid, at sub-cell resolution.
-- Its position is Q6.9 signed fixed point: 9 fractional bits, 6 integer bits
-- and a sign, held in an int32. All the arithmetic below is int32, so it is
-- wrapped explicitly -- the sine approximation in particular relies on
-- overflow behaviour.

local M = {}

-- fixed-point configuration, turtle.h:23
local Q_BITS = 9
local Q_1 = 1 << Q_BITS         -- 1.0
local Q_05 = 1 << (Q_BITS - 1)  -- 0.5

M.WRAP, M.BUMP, M.BOUNCE = 0, 1, 2

-- int32 helpers ----------------------------------------------------------------

local function i32(v)
  v = v & 0xffffffff
  return v >= 0x80000000 and v - 0x100000000 or v
end

--- arithmetic (sign-propagating) right shift, as C does on a signed int
local function asr(x, n)
  return x // (1 << n)
end

--- C remainder: truncates toward zero, so the sign follows the dividend.
-- lua's % floors, which flips the sign for a negative dividend -- and the
-- wrap branch below feeds it exactly that when the turtle runs off the low
-- edge of the fence.
local function cmod(a, b)
  if b == 0 then return 0 end
  local q = a // b
  if q < 0 and q * b ~= a then q = q + 1 end
  return a - q * b
end

local function to_q(x) return i32(x << Q_BITS) end

--- Q to integer cell index. turtle.h:30 -- note the mask to 16 bits, which
--- turns a negative position into a large positive one.
local function to_i(x) return asr(x, Q_BITS) & 0xFFFF end

local function min(a, b) return a < b and a or b end
local function max(a, b) return a > b and a or b end

-- state -------------------------------------------------------------------------

--- turtle.c:6 -- note the defaults: BUMP mode, heading 180, speed 100.
function M.new()
  local t = {
    x = 0, y = 0,               -- Q6.9 position
    last_x = 0, last_y = 0,     -- last resolved cell
    fence = { x1 = 0, y1 = 0, x2 = 3, y2 = 63 },
    mode = M.BUMP,
    heading = 180,
    speed = 100,
    script_number = 12,          -- NO_SCRIPT
    stepping = false, stepped = false, shown = false,
  }
  M.set_x(t, 0)
  M.set_y(t, 0)
  t.last_x, t.last_y = to_i(t.x), to_i(t.y)
  return t
end

--- the fence in Q units. In WRAP mode it spans whole cells; otherwise it is
--- inset by half a cell so the turtle sits in cell centres. turtle.c:23
local function normalize_fence(fence, mode)
  if mode == M.WRAP then
    return {
      x1 = to_q(fence.x1), x2 = to_q(fence.x2 + 1),
      y1 = to_q(fence.y1), y2 = to_q(fence.y2 + 1),
    }
  end
  return {
    x1 = to_q(fence.x1) + (Q_1 >> 1), x2 = to_q(fence.x2 + 1) - (Q_1 >> 1),
    y1 = to_q(fence.y1) + (Q_1 >> 1), y2 = to_q(fence.y2 + 1) - (Q_1 >> 1),
  }
end

--- raise `stepped` when the turtle has crossed into a new cell. turtle.c:42
local function check_step(t)
  local hx, hy = to_i(t.x), to_i(t.y)
  if hx ~= t.last_x or hy ~= t.last_y then
    t.last_x, t.last_y = hx, hy
    t.stepped = true
  end
end

--- constrain the position to the fence according to `mode`. turtle.c:51
function M.normalize_position(t, mode)
  local f = normalize_fence(t.fence, mode)
  local fxl = f.x2 - f.x1
  local fyl = f.y2 - f.y1

  if mode == M.WRAP then
    if fxl > Q_1 and t.x < f.x1 then
      t.x = i32(f.x2 + cmod(t.x - f.x1, fxl))
    elseif fxl > Q_1 and t.x > f.x2 then
      t.x = i32(f.x1 + cmod(t.x - f.x1, fxl))
    end
    if fyl > Q_1 and t.y < f.y1 then
      t.y = i32(f.y2 + cmod(t.y - f.y1, fyl))
    elseif fyl > Q_1 and t.y > f.y2 then
      t.y = i32(f.y1 + cmod(t.y - f.y1, fyl))
    end
  elseif mode == M.BOUNCE then
    -- a wavefolder: reflect repeatedly until inside, flipping the heading
    -- each time if this reflection happened during a step
    local last_x = to_i(t.x)
    while t.x > f.x2 or t.x < f.x1 do
      if t.x > f.x2 then
        if t.stepping then M.set_heading(t, 360 - t.heading) end
        t.x = i32(f.x2 - (t.x - f.x2))
      elseif t.x < f.x1 then
        if t.stepping then M.set_heading(t, 360 - t.heading) end
        t.x = i32(f.x1 + (f.x1 - t.x))
      end
      local here = to_i(t.x)
      if here == last_x then break end
      last_x = here
    end
    local last_y = to_i(t.y)
    while t.y > f.y2 or t.y < f.y1 do
      if t.y >= f.y2 then
        if t.stepping then M.set_heading(t, 180 - t.heading) end
        t.y = i32(f.y2 - (t.y - f.y2))
      elseif t.y < f.y1 then
        if t.stepping then M.set_heading(t, 180 - t.heading) end
        t.y = i32(f.y1 + (f.y1 - t.y))
      end
      local here = to_i(t.y)
      if here == last_y then break end
      last_y = here
    end
    if t.x == f.x2 then t.x = t.x - 1 end
    if t.y == f.y2 then t.y = t.y - 1 end
  end

  -- BUMP, and the backstop for the other two
  t.x = min(f.x2 - 1, max(f.x1, t.x))
  t.y = min(f.y2 - 1, max(f.y1, t.y))
  check_step(t)
end

-- accessors -----------------------------------------------------------------------

function M.get_x(t) return to_i(t.x) & 0xff end   -- returns uint8_t in the C
function M.get_y(t) return to_i(t.y) & 0xff end

function M.set_x(t, x)
  t.x = i32(to_q(x) + Q_05)      -- stand in the middle of the cell
  M.normalize_position(t, M.BUMP)
end

function M.set_y(t, y)
  t.y = i32(to_q(y) + Q_05)
  M.normalize_position(t, M.BUMP)
end

function M.move(t, x, y)
  t.y = i32(t.y + to_q(y))
  t.x = i32(t.x + to_q(x))
  M.normalize_position(t, t.mode)
end

-- movement ---------------------------------------------------------------------------

--- third-order sine approximation, 2^15 units per circle, Q12 output.
-- turtle.c:152, after coranac.com/2009/07/sines. Pure int32 arithmetic,
-- including a deliberate overflow in the quadrant test.
local function _sin(x)
  local qN, qP, qR, qS = 13, 15, 11, 17

  x = i32(x << (30 - qN))
  -- quadrant 1 or 2? the sign of x ^ (x << 1) says so
  if i32(x ~ i32(x << 1)) < 0 then
    x = i32(0x80000000 - x)
  end
  x = asr(x, 30 - qN)

  return i32(asr(i32(x * i32((3 << qP) - asr(i32(x * x), qR))), qS))
end

--- advance by `speed`/100 cells along `heading`. turtle.c:173
function M.step(t)
  local h1 = t.heading % 360
  local h2 = (t.heading + 360 - 90) % 360

  h1 = i32((h1 << 15) // 360)
  h2 = i32((h2 << 15) // 360)

  local dx_q12 = i32(i32(t.speed * _sin(h1)) // 100)
  local dy_q12 = i32(i32(t.speed * _sin(h2)) // 100)

  -- round to Q9, away from zero
  local dx, dy
  if dx_q12 < 0 then dx = asr(asr(dx_q12, 11 - Q_BITS) - 1, 1)
  else dx = asr(asr(dx_q12, 11 - Q_BITS) + 1, 1) end
  if dy_q12 < 0 then dy = asr(asr(dy_q12, 11 - Q_BITS) - 1, 1)
  else dy = asr(asr(dy_q12, 11 - Q_BITS) + 1, 1) end

  t.x = i32(t.x + dx)
  t.y = i32(t.y + dy)
  t.stepping = true
  M.normalize_position(t, t.mode)
  t.stepping = false
end

-- fence and mode -----------------------------------------------------------------------

function M.correct_fence(t)
  local f = t.fence
  f.x1 = min(3, max(0, f.x1))
  f.x2 = min(3, max(0, f.x2))
  f.y1 = min(63, max(0, f.y1))
  f.y2 = min(63, max(0, f.y2))
  if f.x1 > f.x2 then f.x1, f.x2 = f.x2, f.x1 end
  if f.y1 > f.y2 then f.y1, f.y2 = f.y2, f.y1 end
  M.normalize_position(t, M.BUMP)
end

function M.set_fence(t, x1, y1, x2, y2)
  t.fence.x1 = min(3, max(0, x1))
  t.fence.x2 = min(3, max(0, x2))
  t.fence.y1 = min(63, max(0, y1))
  t.fence.y2 = min(63, max(0, y2))
  M.correct_fence(t)
end

function M.set_mode(t, m)
  if m ~= M.WRAP and m ~= M.BUMP and m ~= M.BOUNCE then m = M.BUMP end
  t.mode = m
  M.normalize_position(t, m)
end

function M.set_heading(t, h)
  while h < 0 do h = h + 360 end
  t.heading = h % 360
end

function M.set_script(t, sn)
  -- EDITABLE_SCRIPT_COUNT is 10; anything else detaches the turtle
  if sn >= 10 or sn < 0 then t.script_number = 12 else t.script_number = sn end
  t.stepped = false
end

return M
