-- ui/preset.lua -- the scene slots.
--
-- Ports teletype/module/preset_r_mode.c and preset_w_mode.c. Thirty-two slots,
-- as on hardware, stored as .txt in the script's data folder so a scene can be
-- copied to or from a real Teletype.
--
-- Read mode shows the scene's description text, which is how you tell slots
-- apart; write mode lets you edit that text before saving.

local draw = require 'ui.draw'
local line_editor = require 'ui.line_editor'
local modes = require 'ui.modes'
local scene = require 'scene'

local M = { read = {}, write = {} }

M.SLOTS = 32

local slot = 0
local text_line = 0
local editor = line_editor.new()

--- descriptions of every slot, so the browser can show them. filled by the
--- host through M.set_index, since only it knows where the files live.
M.index = {}

--- what to show for a slot: its description, or why there is none.
-- A slot with no file at all and a slot holding a scene whose description is
-- blank are different situations, and the browser should not make them look
-- the same.
local function first_line(slot_no)
  local t = M.index[slot_no]
  if t == nil then return nil end          -- no file
  if t == '' then return '(untitled)' end  -- a scene, but unnamed
  return t
end

-- ------------------------------------------------------------------- read

--- rescan on entry rather than relying on a save having refreshed the index.
-- Scenes can also arrive over the network, and a browser that shows a stale
-- list is worse than one that costs 32 file opens.
function M.read.enter()
  if modes.on_refresh then modes.on_refresh() end
end

function M.read.key(key, mods)
  local plain = not mods.ctrl and not mods.alt
  if plain and key == 'UP' then
    slot = (slot - 1) % M.SLOTS
  elseif plain and key == 'DOWN' then
    slot = (slot + 1) % M.SLOTS
  elseif plain and key == 'ENTER' then
    if modes.on_load then modes.on_load(slot) end
    modes.set_last()
  end
end

function M.read.enc(n, d)
  if n == 2 then slot = (slot + d) % M.SLOTS end
end

function M.read.norns_key(n, z)
  if z ~= 1 then return end
  if n == 3 then
    if modes.on_load then modes.on_load(slot) end
    modes.set_last()
  end
end

function M.read.redraw()
  draw.text(0, 0, 'load scene', draw.BRIGHT)
  draw.text_right(0, 'enter to load', draw.DIM)

  -- a window of slots around the selected one, as many as the font allows
  local visible = math.max(1, draw.body_rows() + 1)
  local top = math.max(0, math.min(slot - (visible // 2), M.SLOTS - visible))
  for row = 0, visible - 1 do
    local s = top + row
    if s < M.SLOTS then
      local y = draw.body_top() + row
      if s == slot then draw.highlight(y, 2) end
      draw.text(0, y, ('%02d'):format(s),
        s == slot and draw.BRIGHT or draw.DIM)
      local desc = first_line(s)
      draw.text(4, y, desc and desc:sub(1, 27) or 'empty',
        (s == slot and draw.BRIGHT) or (desc and draw.NORMAL) or draw.DIM)
    end
  end
end

-- ------------------------------------------------------------------ write

function M.write.enter()
  if modes.on_refresh then modes.on_refresh() end
  text_line = 0
  editor:set(modes.scene_text and modes.scene_text[0] or '')
end

function M.write.key(key, mods)
  -- `plain` deliberately excludes shift here. Shift-up/down picks the slot and
  -- plain up/down moves through the description; testing a shift-agnostic
  -- `plain` first would swallow the shifted pair entirely.
  local plain = not mods.ctrl and not mods.alt and not mods.shift

  if mods.shift and key == 'UP' then
    slot = (slot - 1) % M.SLOTS
  elseif mods.shift and key == 'DOWN' then
    slot = (slot + 1) % M.SLOTS
  elseif plain and key == 'UP' then
    modes.scene_text[text_line] = editor:get()
    text_line = math.max(0, text_line - 1)
    editor:set(modes.scene_text[text_line] or '')
  elseif plain and key == 'DOWN' then
    modes.scene_text[text_line] = editor:get()
    text_line = math.min(scene.SCENE_TEXT_LINES - 1, text_line + 1)
    editor:set(modes.scene_text[text_line] or '')
  elseif plain and key == 'ENTER' then
    modes.scene_text[text_line] = editor:get()
    if modes.on_save then modes.on_save(slot) end
    modes.set_last()
  else
    editor:key(key, mods)
  end
end

function M.write.char(ch) editor:char(ch) end

function M.write.enc(n, d)
  if n == 2 then slot = (slot + d) % M.SLOTS end
end

function M.write.norns_key(n, z)
  if z == 1 and n == 3 then
    modes.scene_text[text_line] = editor:get()
    if modes.on_save then modes.on_save(slot) end
    modes.set_last()
  end
end

function M.write.redraw()
  draw.text(0, 0, ('save to %02d'):format(slot), draw.BRIGHT)

  -- say what is already in the target slot. overwriting a scene you meant to
  -- keep is not something to discover afterwards.
  local existing = first_line(slot)
  if existing then
    draw.text_right(0, ('over %s'):format(existing:sub(1, 18)), draw.BRIGHT)
  else
    draw.text_right(0, 'shift-up/dn slot', draw.DIM)
  end

  -- the description text around the line being edited
  local visible = math.max(1, draw.body_rows())
  local top = math.max(0, text_line - (visible // 2))
  for row = 0, visible - 1 do
    local l = top + row
    if l < scene.SCENE_TEXT_LINES then
      local y = draw.body_top() + row
      if l == text_line then draw.highlight(y, 2) end
      draw.text(0, y, (modes.scene_text[l] or ''),
        l == text_line and draw.BRIGHT or draw.DIM)
    end
  end

  local prompt = draw.prompt_row()
  draw.text(0, prompt, '>', draw.DIM)
  draw.line_with_cursor(2, prompt, editor:get(), editor.cursor, draw.BRIGHT)
end

function M.set_index(index) M.index = index end
function M.selected() return slot end

return M
