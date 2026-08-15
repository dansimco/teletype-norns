-- ui/draw.lua -- screen helpers for a text UI on a 128x64 screen.
--
-- The grid is assumed, not measured: Particle (face 68) at size 8 is treated
-- as a monospaced 4x8 cell, giving 32 columns and 8 rows. M.CW is the one
-- number to tweak if the glyphs turn out to sit tighter or looser than that --
-- everything else (column stops, the block cursor, M.width) reads from it, so
-- a single edit reflows the whole UI.
--
-- Row count falls out of the line height, and modes lay themselves out from
-- M.ROWS rather than fixed numbers, so changing the font in params reflows
-- rather than pushing content off the bottom of the screen.

local M = {}

M.face = 68           -- Particle
M.size = 8
M.upper = true        -- teletype is an upper-case instrument

M.CW = 4              -- advance per character. tweak me.
M.CH = 8              -- line height; tracks M.size
M.COLS = 32
M.ROWS = 8

M.BRIGHT = 15
M.NORMAL = 8
M.DIM = 3
M.IDLE = 1            -- teletype's unlit indicator level: dim, but not off

--- columns and rows follow from the cell. Called after anything that could
--- change M.CW or M.CH, so a hand-tweaked M.CW above takes effect on load.
local function derive()
  M.COLS = math.max(1, 128 // M.CW)
  M.ROWS = math.max(3, 64 // M.CH)
end

derive()

--- switch font. M.CW is left alone -- it is the hand-set knob.
function M.configure(face, size, upper)
  M.face = face or M.face
  M.size = size or M.size
  if upper ~= nil then M.upper = upper end
  M.CH = M.size
  derive()
end

--- pixel width of a string, assuming the monospaced cell
function M.width(str)
  return #str * M.CW
end

-- ------------------------------------------------------------ symbolic rows
-- Modes place themselves relative to these so a font change reflows rather
-- than pushing content off the bottom.

function M.header_row() return 0 end
function M.prompt_row() return M.ROWS - 1 end
function M.body_top() return 1 end
function M.body_rows() return M.ROWS - 2 end   -- between header and prompt

-- --------------------------------------------------------------------- draw

local function prepare(str)
  str = tostring(str)
  if M.upper then str = str:upper() end
  return str
end

function M.begin()
  screen.clear()
  screen.font_face(M.face)
  screen.font_size(M.size)
  screen.level(M.NORMAL)
end

--- baseline for a row. text sits just above the row's bottom edge.
local function baseline(row)
  return (row + 1) * M.CH - 1
end

--- text at a character column. proportional fonts make this a tab stop
--- rather than a true grid position, which is what tabular layouts want.
function M.text(col, row, str, level)
  screen.level(level or M.NORMAL)
  screen.move(col * M.CW, baseline(row))
  screen.text(prepare(str))
end

--- text at an exact pixel x, for anything that must abut other text
function M.text_at(x, row, str, level)
  screen.level(level or M.NORMAL)
  screen.move(x, baseline(row))
  screen.text(prepare(str))
end

--- right-aligned text. `x` is the right edge, so a caller can stop short of
--- something that owns the rest of the row.
function M.text_right(row, str, level, x)
  screen.level(level or M.NORMAL)
  screen.move(x or 128, baseline(row))
  screen.text_right(prepare(str))
end

--- set a batch of pixels to one level.
--
-- `list` is {{x,y}, ...}. The rects accumulate as subpaths and a single fill
-- covers all of them, so a strip of sixty pixels costs one fill rather than
-- sixty. Integer bounds land exactly on the pixel, as the block cursor below
-- already relies on.
function M.pixels(list, level)
  if #list == 0 then return end
  screen.level(level)
  for _, p in ipairs(list) do screen.rect(p[1], p[2], 1, 1) end
  screen.fill()
end

--- blank a region, for something that must draw over whatever was there
function M.clear_rect(x, y, w, h)
  screen.level(0)
  screen.rect(x, y, w, h)
  screen.fill()
end

--- a filled row, for a selected line
function M.highlight(row, level)
  screen.level(level or 2)
  screen.rect(0, row * M.CH, 128, M.CH)
  screen.fill()
end

--- draw `str` at `row` with a block cursor at character index `cursor`.
--
-- The cursor is placed from the width of the text before it, so it follows
-- M.CW rather than assuming a cell of its own.
function M.line_with_cursor(col, row, str, cursor, level)
  str = prepare(str)
  local x0 = col * M.CW
  M.text_at(x0, row, str, level)

  local prefix = str:sub(1, cursor)
  local cx = x0 + M.width(prefix)
  local ch = str:sub(cursor + 1, cursor + 1)
  local cw = ch ~= '' and M.width(ch) or M.CW

  screen.level(M.BRIGHT)
  screen.rect(cx, row * M.CH, cw, M.CH)
  screen.fill()

  if ch ~= '' then
    screen.level(0)
    screen.move(cx, baseline(row))
    screen.text(ch)
  end
end

function M.finish()
  screen.update()
end

return M
