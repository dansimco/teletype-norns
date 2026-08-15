-- ui/live.lua -- live mode: type a command, press enter, it runs.
--
-- Port of teletype/module/live_mode.c. The scrollback shows what was entered
-- and anything a command returned; `~` toggles the variables panel.

local activity = require 'ui.activity'
local draw = require 'ui.draw'
local exec = require 'exec'
local line_editor = require 'ui.line_editor'
local modes = require 'ui.modes'
local st = require 'state'
local tokenizer = require 'tokenizer'
local validate = require 'validate'

local M = {}

local editor = line_editor.new()
local history = {}          -- previous lines, newest last
local recall = 0            -- how far back up the history we have walked
local show_vars = false

--- push a line onto the scrollback
--- how many scrollback lines fit; depends on the font, so it is asked for
--- rather than fixed
local function history_max()
  return math.max(1, draw.body_rows())
end

local function say(text)
  history[#history + 1] = text
  while #history > history_max() do table.remove(history, 1) end
end

local function execute()
  local text = editor:get()
  if text == '' then return end

  local cmd, perr, pmsg = tokenizer.parse(text:upper())
  if perr ~= 'E_OK' then
    say(text)
    say(tokenizer.error_text(perr) .. (pmsg ~= '' and (': ' .. pmsg) or ''))
    return
  end
  local verr, vmsg = validate.validate(cmd)
  if verr ~= 'E_OK' then
    say(text)
    say(tokenizer.error_text(verr) .. (vmsg ~= '' and (': ' .. vmsg) or ''))
    return
  end

  say(text)
  local es = st.ExecState.new()
  es:push()
  -- LIVE_SCRIPT is the script number a live command reports as; SCRIPT reads 0
  es:vars().script_number = st.LIVE_SCRIPT
  local has_value, value = exec.process_command(modes.ss, es, cmd)
  if has_value then say(tostring(value)) end

  editor:set('')
  recall = 0
end

--- clear the prompt and scrollback for a new scene
function M.reset()
  editor:set('')
  history = {}
  recall = 0
  show_vars = false
end

function M.enter()
  recall = 0
end

function M.key(key, mods)
  local plain = not mods.ctrl and not mods.alt

  if plain and key == 'ENTER' then
    execute()
    return
  end

  -- [ and ] leave live mode for the editor
  if plain and (key == 'LEFTBRACE' or key == 'RIGHTBRACE') then
    modes.set(modes.EDIT)
    return
  end

  -- ~ toggles the variables panel
  if key == 'GRAVE' then
    show_vars = not show_vars
    return
  end

  -- up/down walk the history, which the line editor does not own
  if plain and key == 'UP' then
    if recall < #history then
      recall = recall + 1
      editor:set(history[#history - recall + 1] or '')
    end
    return
  end
  if plain and key == 'DOWN' then
    if recall > 0 then
      recall = recall - 1
      editor:set(recall > 0 and (history[#history - recall + 1] or '') or '')
    end
    return
  end

  editor:key(key, mods)
end

function M.char(ch) editor:char(ch) end

-- norns fallback: E2 walks history, K3 runs the line
function M.enc(n, d)
  if n == 2 then
    if d > 0 then M.key('UP', {}) else M.key('DOWN', {}) end
  end
end

function M.norns_key(n, z)
  if z == 1 and n == 3 then execute() end
end

function M.redraw()
  local ss = modes.ss

  local prompt = draw.prompt_row()

  if show_vars then
    local v = ss.variables
    local rows = {
      ('A %-5d B %-5d C %-5d'):format(v.a, v.b, v.c),
      ('X %-5d Y %-5d Z %-5d'):format(v.x, v.y, v.z),
      ('T %-5d O %-5d D %-5d'):format(v.t, v.o, v.drunk),
      ('CV %5d %5d %5d %5d'):format(v.cv[0], v.cv[1], v.cv[2], v.cv[3]),
      ('TR  %d %d %d %d   M %d'):format(v.tr[0], v.tr[1], v.tr[2], v.tr[3], v.m),
    }
    for i = 1, math.min(#rows, draw.body_rows() + 1) do
      draw.text(0, i - 1, rows[i], i <= 3 and draw.NORMAL or draw.DIM)
    end
  else
    -- scrollback, oldest at the top, ending just above the prompt
    local first_row = prompt - #history
    for i, line in ipairs(history) do
      draw.text(0, first_row + i - 1, line,
        i == #history and draw.NORMAL or draw.DIM)
    end
  end

  -- the prompt is always on the bottom row
  draw.text(0, prompt, '>', draw.DIM)
  draw.line_with_cursor(2, prompt, editor:get(), editor.cursor, draw.BRIGHT)

  -- last, so the strip's band clear covers a scrollback line that reached the
  -- top row -- the hardware clears it after the dashboard for the same reason
  activity.redraw(ss)
end

--- the live scrollback is also where the dashboard PRINT lands
function M.print(text) say(text) end

return M
