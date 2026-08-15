-- ui/pattern.lua -- pattern mode: the tracker.
--
-- Port of teletype/module/pattern_mode.c, reduced to what fits 32x10. Four
-- patterns side by side, the playhead marked, the loop range shaded.
--
-- Typing digits edits the value under the cursor; enter commits it. That
-- differs from the hardware, which edits in place as you type -- but with a
-- 4-pixel-wide font there is no room to show a half-typed value distinctly,
-- and committing explicitly means a mistyped digit never lands in the pattern.

local draw = require 'ui.draw'
local modes = require 'ui.modes'
local st = require 'state'

local M = {}

local pn = 0            -- which pattern column the cursor is in
local idx = 0           -- which step
local top = 0           -- first visible step
local entry = nil       -- digits typed so far, nil when not editing

--- visible steps, from the font's row count rather than a fixed number
local function rows() return math.max(1, draw.body_rows()) end

local function pattern() return modes.ss.patterns[pn] end

local function scroll_into_view()
  local n = rows()
  if idx < top then top = idx end
  if idx >= top + n then top = idx - n + 1 end
  if top < 0 then top = 0 end
end

local function commit()
  if not entry then return end
  local v = tonumber(entry)
  if v then
    local int16 = require 'int16'
    pattern().val[idx] = int16.clamp(v)
    -- writing past the end grows the pattern, as the tracker does
    if idx >= pattern().len then pattern().len = idx + 1 end
  end
  entry = nil
end

--- a half-typed value must not survive into a different scene
function M.reset()
  pn, idx, top, entry = 0, 0, 0, nil
end

function M.enter()
  entry = nil
  pn = modes.ss.variables.p_n
  scroll_into_view()
end

function M.key(key, mods)
  local plain = not mods.ctrl and not mods.alt

  if plain and key == 'DOWN' then
    commit()
    idx = math.min(idx + 1, st.PATTERN_LENGTH - 1)
    scroll_into_view()
  elseif plain and key == 'UP' then
    commit()
    idx = math.max(idx - 1, 0)
    scroll_into_view()
  elseif plain and key == 'LEFT' then
    commit()
    pn = (pn - 1) % st.PATTERN_COUNT
  elseif plain and key == 'RIGHT' then
    commit()
    pn = (pn + 1) % st.PATTERN_COUNT
  elseif plain and key == 'PAGEUP' then
    commit()
    idx = math.max(idx - rows(), 0)
    scroll_into_view()
  elseif plain and key == 'PAGEDOWN' then
    commit()
    idx = math.min(idx + rows(), st.PATTERN_LENGTH - 1)
    scroll_into_view()

  elseif plain and key == 'ENTER' then
    commit()
    idx = math.min(idx + 1, st.PATTERN_LENGTH - 1)
    scroll_into_view()

  elseif plain and key == 'BACKSPACE' then
    if entry and #entry > 0 then
      entry = entry:sub(1, -2)
      if entry == '' then entry = nil end
    else
      pattern().val[idx] = 0
    end

  -- the loop markers, matching the tracker's bindings
  elseif mods.alt and key == 'L' then
    pattern().len = idx + 1
  elseif mods.alt and key == 'S' then
    pattern().start = idx
  elseif mods.alt and key == 'E' then
    pattern()['end'] = idx
  elseif mods.alt and key == 'I' then
    pattern().idx = idx
  end
end

function M.char(ch)
  if ch:match('%d') then
    entry = (entry or '') .. ch
  elseif ch == '-' and (entry == nil or entry == '') then
    entry = '-'
  end
end

function M.enc(n, d)
  if n == 2 then
    commit()
    idx = math.max(0, math.min(idx + d, st.PATTERN_LENGTH - 1))
    scroll_into_view()
  elseif n == 3 then
    local p = pattern()
    local int16 = require 'int16'
    p.val[idx] = int16.clamp(p.val[idx] + d)
    if idx >= p.len then p.len = idx + 1 end
  end
end

function M.norns_key(n, z)
  if z ~= 1 then return end
  if n == 2 then
    commit()
    pn = (pn + 1) % st.PATTERN_COUNT
  elseif n == 3 then
    pattern().idx = idx
  end
end

function M.redraw()
  local ss = modes.ss

  -- header: which pattern is selected, its length and loop range. the column
  -- headings live here too -- at 8 rows a whole line for them is too costly.
  local p = pattern()
  draw.text(0, 0, ('P%d L%d S%d E%d'):format(pn, p.len, p.start, p['end']),
    draw.BRIGHT)
  draw.text_right(0, entry and 'ENTER=SET' or ('W%d'):format(p.wrap), draw.DIM)

  for row = 0, rows() - 1 do
    local step = top + row
    if step < st.PATTERN_LENGTH then
      local y = draw.body_top() + row
      -- the step number, brighter inside the loop range
      local in_loop = step >= p.start and step <= p['end']
      draw.text(0, y, ('%2d'):format(step), in_loop and draw.NORMAL or draw.DIM)

      for c = 0, st.PATTERN_COUNT - 1 do
        local col = ss.patterns[c]
        local value = col.val[step]
        local level = draw.DIM
        if step < col.len then level = draw.NORMAL end
        if c == pn and step == idx then level = draw.BRIGHT end

        local text
        if c == pn and step == idx and entry then
          text = entry            -- what is being typed, not yet committed
        else
          text = tostring(value)
        end
        draw.text(4 + c * 7, y, text, level)

        -- the playhead
        if step == col.idx then
          draw.text(3 + c * 7, y, '>', draw.BRIGHT)
        end
      end
    end
  end

end

return M
