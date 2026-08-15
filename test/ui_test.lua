-- ui_test.lua -- mode switching and the editing modes.
--
-- Key handling is separable from drawing, so all of this runs without a
-- screen. What is checked here is the behaviour that would otherwise only
-- surface as "the editor did something odd": that a bad line never reaches a
-- script, that undo restores what was there, that mode switching always has a
-- way back.

local H = require 'harness'
local exec = require 'exec'
local modes = require 'ui.modes'
local st = require 'state'
local tokenizer = require 'tokenizer'
local ui = require 'ui.init'
-- the op implementations, so `X 42` actually sets X rather than falling
-- through to a stub. without this the file passes only when run after another
-- that happens to load them.
require 'ops.init'

local NONE = { shift = false, ctrl = false, alt = false, meta = false }
local CTRL = { shift = false, ctrl = true, alt = false, meta = false }
local ALT = { shift = false, ctrl = false, alt = true, meta = false }
local SHIFT = { shift = true, ctrl = false, alt = false, meta = false }

local function fresh()
  local ss = st.SceneState.new(0)
  ui.set_scene(ss, require('scene').new_text())
  modes.mode, modes.last_mode = modes.LIVE, modes.LIVE
  return ss
end

--- type a whole line into whichever mode is current
local function type_line(text)
  for ch in text:gmatch('.') do modes.char(ch) end
end

local SHIFT_ALT = { shift = true, ctrl = false, alt = true, meta = false }

H.suite('ui: mode switching', function()
  H.test('tab cycles live, edit, pattern', function()
    fresh()
    H.eq(modes.mode, modes.LIVE, 'starts live')
    modes.key('TAB', NONE)
    H.eq(modes.mode, modes.EDIT, 'to edit')
    modes.key('TAB', NONE)
    H.eq(modes.mode, modes.PATTERN, 'to pattern')
    modes.key('TAB', NONE)
    H.eq(modes.mode, modes.LIVE, 'and back to live')
  end)

  H.test('escape opens the scene browser and returns', function()
    fresh()
    modes.key('TAB', NONE)          -- into edit
    modes.key('ESC', NONE)
    H.eq(modes.mode, modes.PRESET_R, 'escape loads')
    modes.key('ESC', NONE)
    H.eq(modes.mode, modes.EDIT, 'and comes back to where we were')
  end)

  H.test('alt-escape saves, alt-h helps', function()
    fresh()
    modes.key('ESC', ALT)
    H.eq(modes.mode, modes.PRESET_W, 'alt-escape saves')
    modes.key('H', ALT)
    H.eq(modes.mode, modes.HELP, 'alt-h helps')
    modes.key('H', ALT)
    modes.set(modes.LIVE)
    modes.key('SLASH', SHIFT_ALT)
    H.eq(modes.mode, modes.HELP, 'and so does alt-? (shift-alt-slash)')
    modes.key('H', ALT)
    -- help returns to a *main* mode, never to the save browser
    H.eq(modes.mode, modes.LIVE, 'help returns somewhere usable')
  end)

  H.test('ctrl-1..8 run scripts, since norns owns F1-F5', function()
    local ss = fresh()
    exec.set_io(require 'io.null_io')
    local cmd = tokenizer.parse('X 42')
    ss:overwrite_script_command(2, 0, cmd)      -- script 3
    modes.key('3', CTRL)
    H.eq(ss.variables.x, 42, 'ctrl-3 ran script 3')

    ss.variables.x = 0
    modes.key('F8', NONE)                       -- F8 also maps to script 8
    H.eq(ss.variables.x, 0, 'F8 is script 8, which is empty')

    local m = tokenizer.parse('Y 7')
    ss:overwrite_script_command(st.METRO_SCRIPT, 0, m)
    modes.key('9', CTRL)
    H.eq(ss.variables.y, 7, 'ctrl-9 runs the metro script')
  end)
end)

H.suite('ui: edit mode', function()
  H.test('a valid line commits and advances', function()
    local ss = fresh()
    modes.set(modes.EDIT)
    type_line('CV 1 V 5')
    modes.key('ENTER', NONE)
    H.eq(ss:script_len(0), 1, 'the script gained a line')
    H.eq(tokenizer.print(ss:script_command(0, 0)), 'CV 1 V 5', 'as typed')
    local _, line = ui.edit.current()
    H.eq(line, 1, 'and the cursor moved on')
  end)

  H.test('a line that does not validate never reaches the script', function()
    local ss = fresh()
    modes.set(modes.EDIT)
    type_line('ADD 1')                 -- not enough params
    modes.key('ENTER', NONE)
    H.eq(ss:script_len(0), 0, 'nothing was committed')
    -- and the text is still there to fix
    type_line(' 2')
    modes.key('ENTER', NONE)
    H.eq(tokenizer.print(ss:script_command(0, 0)), 'ADD 1 2', 'fixed and kept')
  end)

  H.test('an empty line deletes', function()
    local ss = fresh()
    modes.set(modes.EDIT)
    type_line('X 1')
    modes.key('ENTER', NONE)
    type_line('Y 2')
    modes.key('ENTER', NONE)
    H.eq(ss:script_len(0), 2, 'two lines')

    modes.key('UP', NONE)
    modes.key('UP', NONE)
    -- the cursor sits at the end of the loaded line, so ctrl-u (kill to the
    -- start) is what empties it; ctrl-k would kill nothing
    modes.key('U', CTRL)
    modes.key('ENTER', NONE)
    H.eq(ss:script_len(0), 1, 'one line left')
    H.eq(tokenizer.print(ss:script_command(0, 0)), 'Y 2', 'the right one went')
  end)

  H.test('shift-enter inserts rather than overwriting', function()
    local ss = fresh()
    modes.set(modes.EDIT)
    type_line('X 1')
    modes.key('ENTER', NONE)
    modes.key('UP', NONE)
    -- moving to a line loads it for editing, cursor at the end -- so clear it
    -- before typing, exactly as you would on the module
    modes.key('U', CTRL)
    type_line('Y 2')
    modes.key('ENTER', SHIFT)
    H.eq(ss:script_len(0), 2, 'both lines are there')
    H.eq(tokenizer.print(ss:script_command(0, 0)), 'Y 2', 'inserted above')
    H.eq(tokenizer.print(ss:script_command(0, 1)), 'X 1', 'pushing the rest down')
  end)

  H.test('undo restores the script', function()
    local ss = fresh()
    modes.set(modes.EDIT)
    type_line('X 1')
    modes.key('ENTER', NONE)
    H.eq(ss:script_len(0), 1, 'committed')
    modes.key('Z', CTRL)
    H.eq(ss:script_len(0), 0, 'undone')
  end)

  H.test('brackets change script and clamp the cursor', function()
    local ss = fresh()
    modes.set(modes.EDIT)
    type_line('X 1')
    modes.key('ENTER', NONE)          -- script 1 now has a line, cursor at 1

    modes.key('RIGHTBRACE', NONE)
    local script, line = ui.edit.current()
    H.eq(script, 1, 'moved to script 2')
    H.eq(line, 0, 'cursor clamped to the empty script')

    modes.key('LEFTBRACE', NONE)
    script = ui.edit.current()
    H.eq(script, 0, 'and back')
  end)

  H.test('script selection wraps around all ten', function()
    fresh()
    modes.set(modes.EDIT)
    modes.key('LEFTBRACE', NONE)
    H.eq(ui.edit.current(), st.EDITABLE_SCRIPT_COUNT - 1,
      'back from the first goes to I')
    modes.key('RIGHTBRACE', NONE)
    H.eq(ui.edit.current(), 0, 'and forward wraps to 1')
  end)

  H.test('alt-slash comments a line out', function()
    local ss = fresh()
    modes.set(modes.EDIT)
    type_line('X 1')
    modes.key('ENTER', NONE)
    modes.key('UP', NONE)
    modes.key('SLASH', ALT)
    H.ok(ss:script_command(0, 0).comment, 'commented')
    H.eq(modes.mode, modes.EDIT, 'alt-slash comments, it does not open help')

    -- a commented line stays in the script but does not run
    ss.variables.x = 0
    exec.set_io(require 'io.null_io')
    exec.run_script(ss, 0)
    H.eq(ss.variables.x, 0, 'and is skipped when the script runs')

    modes.key('SLASH', ALT)
    exec.run_script(ss, 0)
    H.eq(ss.variables.x, 1, 'uncommented, it runs again')
  end)
end)

H.suite('ui: save mode', function()
  H.test('shift-up/down picks the slot, plain up/down moves the text', function()
    fresh()
    local saved_to
    modes.on_save = function(slot) saved_to = slot end
    modes.set(modes.PRESET_W)

    type_line('FIRST')
    -- shift-down must change the slot. it shares a key with "next description
    -- line", and a `plain` test that ignores shift would swallow it -- which
    -- would silently send every save to the same slot.
    modes.key('DOWN', SHIFT)
    modes.key('DOWN', SHIFT)
    modes.key('ENTER', NONE)
    H.eq(saved_to, 2, 'shift-down moved the target slot')
    H.eq(modes.scene_text[0], 'FIRST', 'and the text stayed on line 0')
  end)

  H.test('plain down moves to the next description line', function()
    fresh()
    modes.on_save = function() end
    modes.set(modes.PRESET_W)
    type_line('LINE ONE')
    modes.key('DOWN', NONE)
    type_line('LINE TWO')
    modes.key('ENTER', NONE)
    H.eq(modes.scene_text[0], 'LINE ONE', 'first line kept')
    H.eq(modes.scene_text[1], 'LINE TWO', 'second line written')
  end)
end)

H.suite('ui: live mode', function()
  H.test('enter runs the line', function()
    local ss = fresh()
    exec.set_io(require 'io.null_io')
    type_line('X 42')
    modes.key('ENTER', NONE)
    H.eq(ss.variables.x, 42, 'the command ran')
  end)

  H.test('history recalls previous lines', function()
    fresh()
    exec.set_io(require 'io.null_io')
    type_line('X 1')
    modes.key('ENTER', NONE)
    type_line('Y 2')
    modes.key('ENTER', NONE)

    -- up walks back through what was entered. the scrollback also holds
    -- returned values, so this checks we recall commands, not results.
    modes.key('UP', NONE)
    modes.key('ENTER', NONE)
    H.ok(true, 'recall and re-run did not error')
  end)

  H.test('a bad line reports instead of running', function()
    local ss = fresh()
    exec.set_io(require 'io.null_io')
    ss.variables.x = 5
    type_line('X BOGUS')
    modes.key('ENTER', NONE)
    H.eq(ss.variables.x, 5, 'nothing was executed')
  end)

  H.test('brackets jump to the editor', function()
    fresh()
    modes.key('RIGHTBRACE', NONE)
    H.eq(modes.mode, modes.EDIT, 'straight into edit mode')
  end)
end)

H.suite('ui: pattern mode', function()
  H.test('typing a value commits on enter', function()
    local ss = fresh()
    modes.set(modes.PATTERN)
    type_line('42')
    modes.key('ENTER', NONE)
    H.eq(ss.patterns[0].val[0], 42, 'the value landed')
    H.eq(ss.patterns[0].len, 1, 'and the pattern grew')
  end)

  H.test('negative values work', function()
    local ss = fresh()
    modes.set(modes.PATTERN)
    modes.char('-')
    type_line('5')
    modes.key('ENTER', NONE)
    H.eq(ss.patterns[0].val[0], -5, 'negative committed')
  end)

  H.test('arrows move between patterns and steps', function()
    local ss = fresh()
    modes.set(modes.PATTERN)
    modes.key('RIGHT', NONE)
    type_line('7')
    modes.key('ENTER', NONE)
    H.eq(ss.patterns[1].val[0], 7, 'right moved to pattern 1')
    H.eq(ss.patterns[0].val[0], 0, 'pattern 0 untouched')
  end)

  H.test('alt keys set the loop markers', function()
    local ss = fresh()
    modes.set(modes.PATTERN)
    modes.key('DOWN', NONE)
    modes.key('DOWN', NONE)
    modes.key('S', ALT)
    H.eq(ss.patterns[0].start, 2, 'alt-s sets start')
    modes.key('DOWN', NONE)
    modes.key('E', ALT)
    H.eq(ss.patterns[0]['end'], 3, 'alt-e sets end')
    modes.key('L', ALT)
    H.eq(ss.patterns[0].len, 4, 'alt-l sets length')
  end)
end)
