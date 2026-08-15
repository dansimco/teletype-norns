-- editor_test.lua -- the line editor's key handling.
--
-- Worth testing properly because the bindings are emacs-flavoured and full of
-- near-misses: ctrl-d deletes a character but alt-d kills a word, backspace
-- deletes one but shift-backspace kills to the start of the line.

local H = require 'harness'
local line_editor = require 'ui.line_editor'

local NONE = { shift = false, ctrl = false, alt = false }
local CTRL = { shift = false, ctrl = true, alt = false }
local ALT = { shift = false, ctrl = false, alt = true }
local SHIFT = { shift = true, ctrl = false, alt = false }

--- build an editor holding `text` with the cursor at `at`
local function at(text, cursor)
  local e = line_editor.new()
  e:set(text)
  e.cursor = cursor or #text
  return e
end

--- render as "buffer|cursor" so a failure shows both at once
local function show(e)
  return e.buffer:sub(1, e.cursor) .. '|' .. e.buffer:sub(e.cursor + 1)
end

H.suite('line editor', function()
  H.test('typing folds to upper case', function()
    local e = line_editor.new()
    for ch in ('cv 1'):gmatch('.') do e:char(ch) end
    H.eq(e:get(), 'CV 1', 'teletype is upper case only')
    H.eq(e.cursor, 4, 'cursor follows the text')
  end)

  H.test('a line cannot exceed what a scene file holds', function()
    local e = line_editor.new()
    for _ = 1, 40 do e:char('X') end
    H.eq(#e:get(), line_editor.SIZE, 'capped at 31 characters')
  end)

  H.test('insertion happens at the cursor', function()
    local e = at('CV 1', 2)
    e:char('x')
    H.eq(show(e), 'CVX| 1', 'inserted mid-line')
  end)

  H.test('character motion', function()
    local e = at('CV 1', 4)
    e:key('LEFT', NONE)
    H.eq(show(e), 'CV |1', 'left')
    e:key('RIGHT', NONE)
    H.eq(show(e), 'CV 1|', 'right')
    e:key('HOME', NONE)
    H.eq(show(e), '|CV 1', 'home')
    e:key('END', NONE)
    H.eq(show(e), 'CV 1|', 'end')
    -- and the emacs equivalents
    e:key('A', CTRL)
    H.eq(show(e), '|CV 1', 'ctrl-a')
    e:key('F', CTRL)
    H.eq(show(e), 'C|V 1', 'ctrl-f')
    e:key('B', CTRL)
    H.eq(show(e), '|CV 1', 'ctrl-b')
    e:key('E', CTRL)
    H.eq(show(e), 'CV 1|', 'ctrl-e')
  end)

  H.test('motion stops at the ends', function()
    local e = at('AB', 0)
    e:key('LEFT', NONE)
    H.eq(e.cursor, 0, 'cannot go left of the start')
    e.cursor = 2
    e:key('RIGHT', NONE)
    H.eq(e.cursor, 2, 'cannot go right of the end')
  end)

  H.test('word motion skips runs of spaces', function()
    local e = at('CV 1 V 5', 8)
    e:key('LEFT', CTRL)
    H.eq(show(e), 'CV 1 V |5', 'back one word')
    e:key('LEFT', CTRL)
    H.eq(show(e), 'CV 1 |V 5', 'and another')
    e:key('RIGHT', CTRL)
    H.eq(show(e), 'CV 1 V| 5', 'forward one word')
    -- alt-b / alt-f are the same motions
    e:key('B', ALT)
    H.eq(show(e), 'CV 1 |V 5', 'alt-b')
    e:key('F', ALT)
    H.eq(show(e), 'CV 1 V| 5', 'alt-f')
  end)

  H.test('backspace and delete', function()
    local e = at('CV 1', 2)
    e:key('BACKSPACE', NONE)
    H.eq(show(e), 'C| 1', 'backspace removes behind')
    e:key('DELETE', NONE)
    H.eq(show(e), 'C|1', 'delete removes ahead')
    e:key('H', CTRL)
    H.eq(show(e), '|1', 'ctrl-h is backspace')
    e:key('D', CTRL)
    H.eq(show(e), '|', 'ctrl-d is delete')
  end)

  H.test('deletion stops at the ends', function()
    local e = at('AB', 0)
    e:key('BACKSPACE', NONE)
    H.eq(e:get(), 'AB', 'nothing behind the start')
    e.cursor = 2
    e:key('DELETE', NONE)
    H.eq(e:get(), 'AB', 'nothing past the end')
  end)

  H.test('killing to either end', function()
    local e = at('CV 1 V 5', 5)
    e:key('BACKSPACE', SHIFT)
    H.eq(show(e), '|V 5', 'shift-backspace kills to the start')

    e = at('CV 1 V 5', 5)
    e:key('DELETE', SHIFT)
    H.eq(show(e), 'CV 1 |', 'shift-delete kills to the end')

    e = at('CV 1 V 5', 5)
    e:key('U', CTRL)
    H.eq(show(e), '|V 5', 'ctrl-u kills to the start')

    e = at('CV 1 V 5', 5)
    e:key('K', CTRL)
    H.eq(show(e), 'CV 1 |', 'ctrl-k kills to the end')
  end)

  H.test('killing words', function()
    local e = at('CV 1 V 5', 8)
    e:key('W', CTRL)
    H.eq(show(e), 'CV 1 V |', 'ctrl-w kills the word behind')
    e:key('BACKSPACE', ALT)
    H.eq(show(e), 'CV 1 |', 'alt-backspace does the same')

    e = at('CV 1 V 5', 0)
    e:key('D', ALT)
    H.eq(show(e), '| 1 V 5', 'alt-d kills the word ahead')
  end)

  H.test('alt-d and ctrl-d are different keys', function()
    -- the pair most likely to be confused in a port
    local e = at('CV 1', 0)
    e:key('D', CTRL)
    H.eq(e:get(), 'V 1', 'ctrl-d removes one character')
    e = at('CV 1', 0)
    e:key('D', ALT)
    H.eq(e:get(), ' 1', 'alt-d removes the whole word')
  end)

  H.test('cut, copy and paste share one slot', function()
    local e = at('CV 1 V 5')
    e:key('X', CTRL)
    H.eq(e:get(), '', 'cut empties the line')
    H.eq(line_editor.clipboard, 'CV 1 V 5', 'and fills the clipboard')

    local other = line_editor.new()
    other:key('V', CTRL)
    H.eq(other:get(), 'CV 1 V 5', 'paste lands in a different editor')

    local third = at('TR.P A')
    third:key('C', CTRL)
    H.eq(third:get(), 'TR.P A', 'copy leaves the line alone')
    H.eq(line_editor.clipboard, 'TR.P A', 'and replaces the clipboard')
  end)

  H.test('unhandled keys are refused so the caller can use them', function()
    local e = line_editor.new()
    H.eq(e:key('TAB', NONE), false, 'tab belongs to mode switching')
    H.eq(e:key('ESC', NONE), false, 'escape too')
    H.eq(e:key('F6', NONE), false, 'and the function keys')
    H.eq(e:key('LEFT', NONE), true, 'but motion is claimed')
  end)
end)
