-- ui/draw.lua -- screen helpers for a text UI on a 128x64 screen.
--
-- This does not use a norns font. It renders Teletype's own bitmap font,
-- lib/ui/font.lua, generated from teletype/libavr32/src/font.c -- so text on
-- norns is pixel-identical to text on the module rather than an approximation
-- of it in whichever TTF came closest.
--
-- The mechanism is the same one the hardware uses. Teletype draws into a
-- `region`: a flat buffer holding one byte per pixel, each a level from 0 to
-- 15 (libavr32/src/region.h). norns' screen.poke takes exactly that -- a byte
-- per pixel, 0-15, blitted straight to the framebuffer -- so a frame here is
-- built the same way and handed over in one call. Nothing else in the script
-- touches screen.*, which is why swapping the renderer changed no mode.
--
-- The font is proportional. Advances come from font_string_pixels: a glyph
-- occupies (6 - first - last) columns and is followed by one blank column, so
-- most uppercase and digits are 4px but `.` and `:` are 2, `-` and `J` are 3,
-- `N` is 5, and `M` and `W` are 6. M.width is therefore exact, and the block
-- cursor lands on the character it marks however the line is spelled.
--
-- M.CW survives as a tab stop only -- the unit for column-addressed layout in
-- tabular modes. The hardware does the same thing, positioning the variables
-- panel at 11*4 and 14*4 (live_mode.c:795-830). It is not a claim that every
-- character is 4 pixels wide.

local font = require 'ui.font'

local M = {}

local W, H = 128, 64

M.upper = true -- teletype is an upper-case instrument

M.CW = 4       -- tab stop width for column-addressed layout
M.CH = font.CHARH
M.COLS = W // 4
M.ROWS = H // font.CHARH

M.BRIGHT = 15
M.NORMAL = 8
M.DIM = 3
M.IDLE = 1 -- teletype's unlit indicator level: dim, but not off

-- ------------------------------------------------------------------- glyphs

-- Each glyph becomes its advance plus a flat list of the pixels it sets, so
-- drawing a character is a walk of that list rather than a scan of 6 columns
-- by 8 rows. Built once at load.
--
-- font_glyph draws column i from data[i + first], and row j from bit j, for
-- (6 - first - last) columns.
local GLYPH = {}
do
    for i, g in ipairs(font.glyphs) do
        local first, last, cols = g[1], g[2], g[3]
        local n = font.CHARW - first - last
        local px = {}
        for c = 0, n - 1 do
            local col = cols[c + first + 1]
            for y = 0, font.CHARH - 1 do
                if (col >> y) & 1 == 1 then
                    px[#px + 1] = c
                    px[#px + 1] = y
                end
            end
        end
        -- font_string puts a single blank column between characters
        GLYPH[string.char(font.ASCII_OFFSET + i - 1)] = { adv = n + 1, px = px }
    end
end

-- ------------------------------------------------------------------ buffer

-- one byte per pixel, 0-15, indexed y*W + x + 1
local buf = {}
for i = 1, W * H do buf[i] = 0 end

--- pixels dropped off the bottom of the screen since the last M.begin.
--
-- Clipping at the right edge is deliberate -- font_string_region_clip does the
-- same -- but nothing should ever draw below the last row, and without a
-- count that mistake is invisible: the pixels simply vanish. A mode that lays
-- itself out from the wrong row count trips this.
M.overflow = 0

local function plot(x, y, level)
    if y < 0 or y >= H then
        M.overflow = M.overflow + 1
        return
    end
    if x >= 0 and x < W then buf[y * W + x + 1] = level end
end

--- pixel width of a string, from the font's own advances
function M.width(str)
    local n = 0
    for i = 1, #str do
        local g = GLYPH[str:sub(i, i)]
        if g then n = n + g.adv end
    end
    return n
end

local function prepare(str)
    str = tostring(str)
    if M.upper then str = str:upper() end
    return str
end

--- draw a prepared string at a pixel position, clipping at the right edge as
--- font_string_region_clip does. Returns the x it ended at.
local function put(x, y, str, level)
    for i = 1, #str do
        local g = GLYPH[str:sub(i, i)]
        if g then
            if x >= W then return x end
            local px = g.px
            for k = 1, #px, 2 do plot(x + px[k], y + px[k + 1], level) end
            x = x + g.adv
        end
    end
    return x
end

-- ------------------------------------------------------------ symbolic rows
-- Modes place themselves relative to these rather than fixed numbers.

function M.header_row() return 0 end

function M.prompt_row() return M.ROWS - 1 end

function M.body_top() return 1 end

function M.body_rows() return M.ROWS - 2 end -- between header and prompt

--- kept for the params page: the only display choice left is letter case,
--- since the font and its size are the hardware's and no longer ours to pick.
function M.configure(upper)
    if upper ~= nil then M.upper = upper end
end

-- --------------------------------------------------------------------- draw

function M.begin()
    for i = 1, W * H do buf[i] = 0 end
    M.overflow = 0
end

--- text at a character column -- a tab stop, not a true grid position, which
--- is what the tabular layouts want.
function M.text(col, row, str, level)
    put(col * M.CW, row * M.CH, prepare(str), level or M.NORMAL)
end

--- text at an exact pixel x, for anything that must abut other text
function M.text_at(x, row, str, level)
    put(x, row * M.CH, prepare(str), level or M.NORMAL)
end

--- right-aligned text. `x` is the right edge, so a caller can stop short of
--- something that owns the rest of the row.
function M.text_right(row, str, level, x)
    str = prepare(str)
    local right = x or W
    put(math.max(0, right - M.width(str)), row * M.CH, str, level or M.NORMAL)
end

--- set a batch of pixels to one level. `list` is {{x,y}, ...}.
function M.pixels(list, level)
    for _, p in ipairs(list) do plot(p[1], p[2], level) end
end

--- blank a region, for something that must draw over whatever was there
function M.clear_rect(x, y, w, h)
    M.fill_rect(x, y, w, h, 0)
end

function M.fill_rect(x, y, w, h, level)
    for yy = y, y + h - 1 do
        for xx = x, x + w - 1 do plot(xx, yy, level) end
    end
end

--- a filled row, for a selected line
function M.highlight(row, level)
    M.fill_rect(0, row * M.CH, W, M.CH, level or 2)
end

--- draw `str` at `row` with a block cursor at character index `cursor`.
--
-- The cursor is placed and sized from the font's real advances, so it sits on
-- the character it marks whatever that character is.
function M.line_with_cursor(col, row, str, cursor, level)
    str = prepare(str)
    local y = row * M.CH
    local x0 = col * M.CW
    put(x0, y, str, level)

    local cx = x0 + M.width(str:sub(1, cursor))
    local ch = str:sub(cursor + 1, cursor + 1)
    local g = GLYPH[ch]
    local cw = g and g.adv or M.CW

    M.fill_rect(cx, y, cw, M.CH, M.BRIGHT)
    if g then put(cx, y, ch, 0) end
end

-- --------------------------------------------------------------------- out

--- hand the frame over. string.char is fed in chunks because it passes each
--- byte as an argument, and a whole screen at once is 8192 of them.
local chunk = {}
function M.finish()
    local n = 0
    for i = 1, W * H, 256 do
        n = n + 1
        chunk[n] = string.char(table.unpack(buf, i, math.min(i + 255, W * H)))
    end
    screen.poke(0, 0, W, H, table.concat(chunk, '', 1, n))
    screen.update()
end

--- the frame as it stands, for tests and for rendering to text
function M.buffer() return buf, W, H end

return M
