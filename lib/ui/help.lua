-- ui/help.lua -- browse the op reference.
--
-- The hardware carries 100KB of help text. Here the summaries come from the
-- same TOML the official docs are built from (lib/ops/help.lua, generated), so
-- they cannot drift from the reference.
--
-- Type to filter. That is more useful on a 32-column screen than paging
-- through categories, and it is how you actually use it: you half-remember
-- `P.` something and want to see what exists.

local draw = require 'ui.draw'
local help_data = require 'ops.help'
local manifest = require 'ops.manifest'
local modes = require 'ui.modes'

local M = {}

local filter = ''
local sel = 0
local matches = {}

--- arity, for the one op with no doc entry and as a fallback
local function arity(name)
  for _, o in ipairs(manifest.ops) do
    if o[1] == name then
      return ('%d arg%s%s'):format(o[2], o[2] == 1 and '' or 's',
        o[3] and ', returns' or '')
    end
  end
  for _, m in ipairs(manifest.mods) do
    if m[1] == name then return ('mod, %d arg'):format(m[2]) end
  end
  return ''
end

local function rebuild()
  matches = {}
  local needle = filter:upper()
  for _, name in ipairs(help_data.names) do
    if needle == '' or name:find(needle, 1, true) == 1 then
      matches[#matches + 1] = name
    end
  end
  -- fall back to a substring match if nothing starts with the filter
  if #matches == 0 and needle ~= '' then
    for _, name in ipairs(help_data.names) do
      if name:find(needle, 1, true) then matches[#matches + 1] = name end
    end
  end
  if sel >= #matches then sel = math.max(0, #matches - 1) end
end

function M.enter()
  rebuild()
end

--- open help already filtered to a word, for a "what is this op" jump
function M.show(name)
  filter = name or ''
  sel = 0
  rebuild()
end

function M.key(key, mods)
  local plain = not mods.ctrl and not mods.alt

  if plain and key == 'DOWN' then
    sel = math.min(sel + 1, math.max(0, #matches - 1))
  elseif plain and key == 'UP' then
    sel = math.max(sel - 1, 0)
  elseif plain and key == 'BACKSPACE' then
    filter = filter:sub(1, -2)
    sel = 0
    rebuild()
  elseif plain and key == 'ENTER' then
    modes.set_last()
  end
end

function M.char(ch)
  filter = filter .. ch:upper()
  sel = 0
  rebuild()
end

function M.enc(n, d)
  if n == 2 then
    sel = math.max(0, math.min(sel + d, math.max(0, #matches - 1)))
  end
end

function M.norns_key(n, z)
  if z == 1 and n == 3 then modes.set_last() end
end

--- wrap `text` to `width` columns, at most `limit` lines
local function wrap(text, width, limit)
  local lines, line = {}, ''
  for word in text:gmatch('%S+') do
    if line == '' then
      line = word
    elseif #line + 1 + #word <= width then
      line = line .. ' ' .. word
    else
      lines[#lines + 1] = line
      if #lines >= limit then return lines end
      line = word
    end
  end
  if line ~= '' and #lines < limit then lines[#lines + 1] = line end
  return lines
end

function M.redraw()
  draw.text(0, 0, 'help', draw.BRIGHT)
  draw.text_right(0, ('%d'):format(#matches), draw.DIM)

  local body_top = draw.body_top()
  local body = draw.body_rows()
  -- split the body: a short list of names, the rest describing the selected
  -- one. with only six rows the list gets two and the detail gets four.
  local list_rows = math.max(1, math.floor(body / 3))
  local detail_top = body_top + list_rows

  if #matches == 0 then
    draw.text(0, body_top, 'no match', draw.DIM)
  else
    local top = math.max(0, math.min(sel - (list_rows // 2),
      math.max(0, #matches - list_rows)))
    for row = 0, list_rows - 1 do
      local i = top + row + 1
      local name = matches[i]
      if name then
        local y = body_top + row
        if i - 1 == sel then draw.highlight(y, 2) end
        draw.text(0, y, name, i - 1 == sel and draw.BRIGHT or draw.NORMAL)
      end
    end

    local name = matches[sel + 1]
    local entry = help_data.get(name)
    local y = detail_top
    if entry then
      local proto, proto_set, short, alias_of = entry[1], entry[2], entry[3],
        entry[4]
      draw.text(0, y, proto, draw.BRIGHT); y = y + 1
      if proto_set and y < draw.prompt_row() then
        draw.text(0, y, proto_set, draw.NORMAL); y = y + 1
      end
      local text = short
      if alias_of then text = ('= %s. %s'):format(alias_of, short) end
      local remaining = draw.prompt_row() - y
      if remaining > 0 then
        for i, l in ipairs(wrap(text, draw.COLS, remaining)) do
          draw.text(0, y + i - 1, l, draw.DIM)
        end
      end
    else
      draw.text(0, y, name, draw.BRIGHT)
      draw.text(0, y + 1, arity(name), draw.DIM)
    end
  end

  local prompt = draw.prompt_row()
  draw.text(0, prompt, '/', draw.DIM)
  draw.text(2, prompt, filter, draw.BRIGHT)
end

return M
