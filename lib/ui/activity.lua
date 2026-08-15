-- ui/activity.lua -- the LIVE mode indicator strip.
--
-- Port of refresh_activities() in teletype/module/live_mode.c:658-728, which
-- writes single bytes straight into the top line's framebuffer rather than
-- going through the font. The region is declared in module/main.c:83 as
-- { .w = 128, .h = 8, .x = 0, .y = 0 }, indexed x + 128*y, one byte per pixel
-- holding a level of 0-15.
--
-- norns' screen is also 128x64 with 16 grey levels, so every coordinate below
-- is the hardware's own, unscaled. Lit is 15 and unlit is 1 -- dim, not off,
-- so the strip is always legible as a row of four icons.
--
-- Documented in teletype/docs/quickstart.md:39-46, which covers the four state
-- icons; the mute marks are undocumented there.

local draw = require 'ui.draw'
local st = require 'state'

local M = {}

-- Decoded from the pixel writes in live_mode.c. Five rows, y = 0..4.
local GLYPH = {
  slew  = { '....#', '...#.', '..#..', '.#...', '#....' },
  delay = { '#####', '#...#', '#...#', '#...#', '#...#' },
  stack = { '#####', '.....', '#####', '.....', '#####' },
  metro = { '#...#', '##.##', '#.#.#', '#...#', '#...#' },
}

-- left edge of each glyph, and the order they read in
local ICONS = {
  { name = 'slew', x = 98 },
  { name = 'delay', x = 106 },
  { name = 'stack', x = 114 },
  { name = 'metro', x = 122 },
}

-- the band live_mode.c:647-652 clears before drawing: x 85..127, the full row
local BAND_X, BAND_W = 85, 43
local MUTE_X = 87

--- the io backend, for the one flag that is not in the scene state.
-- Left nil under the null backend and in tests, where nothing slews.
M.io = nil

--- is a CV output still ramping?
--
-- On the hardware this is read off the DAC refresh loop (module/main.c:220)
-- because the module runs the ramp itself. crow resolves slews on-board, so
-- the io layer tracks when each ramp is due to finish instead.
local function slewing()
  return M.io ~= nil and M.io.slewing()
end

--- which icons are lit, in the order ICONS lists them
local function flags(ss)
  return {
    slew = slewing(),
    delay = ss.delay.count > 0,
    stack = ss.stack_op.top > 0,
    -- main.c:1028-1031: the metro timer running is not enough, the script has
    -- to have something in it
    metro = ss.variables.m_act ~= 0
      and ss:script_len(st.METRO_SCRIPT) > 0,
  }
end

--- collect the pixels of one glyph into `lit` or `idle`
local function stamp(rows, x0, on, lit, idle)
  local into = on and lit or idle
  for y = 1, #rows do
    local row = rows[y]
    for x = 1, #row do
      if row:sub(x, x) == '#' then
        into[#into + 1] = { x0 + x - 1, y - 1 }
      end
    end
  end
end

--- the eight mute marks.
--
-- live_mode.c:716-725. Script i sits at x = 87+i, staggered onto row 1 for
-- even i and row 3 for odd i so neighbours cannot collide when a falling
-- polarity widens a mark to two pixels. Bright means *muted*, which is how
-- the C reads it.
local function stamp_mutes(ss, lit, idle)
  local v = ss.variables
  for i = 0, st.TRIGGER_INPUTS - 1 do
    local y = (i % 2 == 0) and 1 or 3
    local into = v.mutes[i] and lit or idle
    local pol = v.script_pol[i] or 0
    if pol & 1 ~= 0 then into[#into + 1] = { MUTE_X + i, y } end
    if pol & 2 ~= 0 then into[#into + 1] = { MUTE_X + i + 1, y } end
  end
end

--- draw the strip. Call last, so the band clear covers whatever the mode put
--- on the top row -- the C clears it after the dashboard for the same reason.
function M.redraw(ss)
  if not ss then return end

  draw.clear_rect(BAND_X, 0, BAND_W, draw.CH)

  local lit, idle = {}, {}
  local on = flags(ss)
  for _, icon in ipairs(ICONS) do
    stamp(GLYPH[icon.name], icon.x, on[icon.name], lit, idle)
  end
  stamp_mutes(ss, lit, idle)

  draw.pixels(idle, draw.IDLE)
  draw.pixels(lit, draw.BRIGHT)
end

-- exposed for the geometry test, which checks the drawn pixels against these
M.GLYPH = GLYPH
M.ICONS = ICONS
M.BAND_X, M.BAND_W, M.MUTE_X = BAND_X, BAND_W, MUTE_X

return M
