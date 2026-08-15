-- ui/edit.lua -- edit mode: the six lines of a script.
--
-- Port of teletype/module/edit_mode.c. `[` and `]` change script, up/down
-- change line, enter commits the edited line, shift-enter inserts one.
--
-- A line only commits if it parses *and* validates -- a bad line stays in the
-- editor with the error shown, so nothing half-typed ever reaches a script.

local command = require 'command'
local draw = require 'ui.draw'
local line_editor = require 'ui.line_editor'
local modes = require 'ui.modes'
local st = require 'state'
local tokenizer = require 'tokenizer'
local validate = require 'validate'

local M = {}

local editor = line_editor.new()
local script = 0            -- 0..9, where 8 is M and 9 is I
local line_no = 0           -- 0-based
local message = ''

local undo = nil            -- one level, as on hardware

local SCRIPT_LABEL = { [st.METRO_SCRIPT] = 'M', [st.INIT_SCRIPT] = 'I' }
local function label(n) return SCRIPT_LABEL[n] or tostring(n + 1) end

--- copy the whole script so a single undo can put it back
local function save_undo()
  local ss = modes.ss
  local lines = {}
  for l = 0, st.SCRIPT_MAX_COMMANDS - 1 do
    lines[l] = command.copy(ss:script_command(script, l))
  end
  undo = { script = script, len = ss:script_len(script), lines = lines }
end

local function do_undo()
  if not undo then return end
  local ss = modes.ss
  for l = 0, st.SCRIPT_MAX_COMMANDS - 1 do
    ss.scripts[undo.script].c[l] = command.copy(undo.lines[l])
  end
  ss.scripts[undo.script].l = undo.len
  undo = nil
  message = 'undo'
end

local function load_line()
  editor:set(tokenizer.print(modes.ss:script_command(script, line_no)))
end

--- compile what is in the editor, reporting any error in `message`
local function compile()
  local cmd, perr, pmsg = tokenizer.parse(editor:get():upper())
  if perr ~= 'E_OK' then
    message = tokenizer.error_text(perr) .. (pmsg ~= '' and (': ' .. pmsg) or '')
    return nil
  end
  local verr, vmsg = validate.validate(cmd)
  if verr ~= 'E_OK' then
    message = tokenizer.error_text(verr) .. (vmsg ~= '' and (': ' .. vmsg) or '')
    return nil
  end
  message = ''
  return cmd
end

--- delete the line at `idx`, shuffling the rest up
local function delete_line(idx)
  local ss = modes.ss
  local s = ss.scripts[script]
  for l = idx, st.SCRIPT_MAX_COMMANDS - 2 do
    s.c[l] = s.c[l + 1]
  end
  s.c[st.SCRIPT_MAX_COMMANDS - 1] =
    { length = 0, separator = -1, data = {}, comment = false }
  if s.l > 0 then s.l = s.l - 1 end
end

local function insert_line(idx, cmd)
  local ss = modes.ss
  local s = ss.scripts[script]
  for l = st.SCRIPT_MAX_COMMANDS - 1, idx + 1, -1 do
    s.c[l] = s.c[l - 1]
  end
  s.c[idx] = command.copy(cmd)
  if s.l < st.SCRIPT_MAX_COMMANDS then s.l = s.l + 1 end
end

--- enter: commit the edited line. an empty line deletes it.
local function commit()
  local ss = modes.ss
  local cmd = compile()
  if not cmd then return end
  save_undo()
  if cmd.length == 0 then
    delete_line(line_no)
    if line_no > ss:script_len(script) then line_no = ss:script_len(script) end
  else
    ss:overwrite_script_command(script, line_no, cmd)
    if line_no < st.SCRIPT_MAX_COMMANDS - 1 then line_no = line_no + 1 end
  end
  load_line()
end

--- start over on a fresh scene: the cursor from the previous one means
--- nothing, and its undo snapshot would restore lines into the wrong scene
function M.reset()
  script, line_no = 0, 0
  message = ''
  undo = nil
  editor:set('')
end

function M.enter()
  load_line()
  message = ''
end

function M.key(key, mods)
  local ss = modes.ss
  local plain = not mods.ctrl and not mods.alt

  if mods.ctrl and key == 'Z' then
    do_undo()
    load_line()

  elseif plain and key == 'LEFTBRACE' then
    script = (script - 1) % st.EDITABLE_SCRIPT_COUNT
    if line_no > ss:script_len(script) then line_no = ss:script_len(script) end
    load_line()
    message = ''
    undo = nil

  elseif plain and key == 'RIGHTBRACE' then
    script = (script + 1) % st.EDITABLE_SCRIPT_COUNT
    if line_no > ss:script_len(script) then line_no = ss:script_len(script) end
    load_line()
    message = ''
    undo = nil

  elseif (plain and key == 'DOWN') or (mods.ctrl and key == 'N') then
    if line_no < st.SCRIPT_MAX_COMMANDS - 1
        and line_no < ss:script_len(script) then
      line_no = line_no + 1
      load_line()
    end

  elseif (plain and key == 'UP') or (mods.ctrl and key == 'P') then
    if line_no > 0 then
      line_no = line_no - 1
      load_line()
    end

  elseif mods.shift and key == 'ENTER' then
    local cmd = compile()
    if cmd and cmd.length > 0 then
      save_undo()
      insert_line(line_no, cmd)
      if line_no < st.SCRIPT_MAX_COMMANDS - 1 then line_no = line_no + 1 end
      load_line()
    end

  elseif plain and key == 'ENTER' then
    commit()

  elseif mods.alt and key == 'DELETE' then
    save_undo()
    delete_line(line_no)
    if line_no > ss:script_len(script) then line_no = ss:script_len(script) end
    load_line()

  -- alt-/ comments the line out, so it stays in the scene but does not run
  elseif mods.alt and key == 'SLASH' then
    local c = ss:script_command(script, line_no)
    if c then
      c.comment = not c.comment
      message = c.comment and 'commented' or 'uncommented'
    end

  else
    editor:key(key, mods)
  end
end

function M.char(ch) editor:char(ch) end

-- norns fallback: E2 picks the script, E3 the line, K2 runs it
function M.enc(n, d)
  local ss = modes.ss
  if n == 2 then
    script = (script + d) % st.EDITABLE_SCRIPT_COUNT
    if line_no > ss:script_len(script) then line_no = ss:script_len(script) end
    load_line()
  elseif n == 3 then
    line_no = util and util.clamp(line_no + d, 0, st.SCRIPT_MAX_COMMANDS - 1)
      or math.max(0, math.min(line_no + d, st.SCRIPT_MAX_COMMANDS - 1))
    load_line()
  end
end

function M.norns_key(n, z)
  if z ~= 1 then return end
  local exec = require 'exec'
  if n == 2 then
    exec.run_script(modes.ss, script)
  elseif n == 3 then
    local c = modes.ss:script_command(script, line_no)
    if c then c.comment = not c.comment end
  end
end

function M.redraw()
  local ss = modes.ss

  draw.text(0, 0, ('#%s'):format(label(script)), draw.BRIGHT)
  if message ~= '' then
    draw.text_right(0, message, draw.NORMAL)
  end

  -- six script lines is exactly the body height at 8 rows
  for l = 0, st.SCRIPT_MAX_COMMANDS - 1 do
    local row = draw.body_top() + l
    local c = ss:script_command(script, l)
    local text = (l < ss:script_len(script)) and tokenizer.print(c) or ''
    if l == line_no then
      draw.highlight(row, 2)
    end
    -- a commented line is shown dim with a leading marker, as on hardware
    if c and c.comment then
      draw.text(0, row, '/ ' .. text, draw.DIM)
    else
      draw.text(0, row, text, l == line_no and draw.BRIGHT or draw.NORMAL)
    end
  end

  local prompt = draw.prompt_row()
  draw.text(0, prompt, '>', draw.DIM)
  draw.line_with_cursor(2, prompt, editor:get(), editor.cursor, draw.BRIGHT)
end

--- the current script, so the host can show it elsewhere
function M.current() return script, line_no end

return M
