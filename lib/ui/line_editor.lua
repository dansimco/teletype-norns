-- ui/line_editor.lua -- one editable line of teletype source.
-- Port of teletype/module/line_editor.c.
--
-- 31 characters plus a terminator on the hardware; kept at 31 here so a line
-- that fits in the editor also fits in a scene file, which allots 32 bytes.
--
-- The key bindings are emacs-flavoured and come straight from the reference:
-- ctrl-a/e for line ends, ctrl-b/f to move, ctrl-h/d to delete, ctrl-u/k to
-- kill to either end, ctrl-w and alt-d for words. Anyone used to the module
-- should find their fingers work.

local M = {}

M.SIZE = 31        -- characters, excluding the terminator the C reserves

--- a shared clipboard, so a line can be cut from one script and pasted in
--- another. the hardware has the same single-slot behaviour.
M.clipboard = ''

local Editor = {}
Editor.__index = Editor
M.Editor = Editor

function M.new()
  return setmetatable({ buffer = '', cursor = 0 }, Editor)
end

function Editor:set(text)
  text = text or ''
  if #text > M.SIZE then
    -- the C refuses an oversized value outright rather than truncating
    self.buffer, self.cursor = '', 0
  else
    self.buffer = text
    self.cursor = #text
  end
end

function Editor:get() return self.buffer end
function Editor:length() return #self.buffer end

--- load a parsed command back into the editor, via its canonical printing
function Editor:set_command(cmd, print_fn)
  self:set(print_fn(cmd))
end

-- ------------------------------------------------------------- word motion

--- scan left from the cursor to the start of the previous word.
-- "encountered_word" is what makes a run of spaces skip through to the word
-- before it rather than stopping at the first space.
local function prev_word(buffer, cursor)
  local encountered = false
  while cursor > 0 do
    if buffer:sub(cursor, cursor) == ' ' then
      if encountered then break end
    else
      encountered = true
    end
    cursor = cursor - 1
  end
  return cursor
end

local function next_word(buffer, cursor, length)
  local encountered = false
  while cursor < length do
    if buffer:sub(cursor + 1, cursor + 1) == ' ' then
      if encountered then break end
    else
      encountered = true
    end
    cursor = cursor + 1
  end
  return cursor
end

-- ---------------------------------------------------------------- editing

function Editor:insert(ch)
  if #self.buffer >= M.SIZE then return false end
  self.buffer = self.buffer:sub(1, self.cursor) .. ch
    .. self.buffer:sub(self.cursor + 1)
  self.cursor = self.cursor + 1
  return true
end

function Editor:backspace()
  if self.cursor == 0 then return end
  self.buffer = self.buffer:sub(1, self.cursor - 1)
    .. self.buffer:sub(self.cursor + 1)
  self.cursor = self.cursor - 1
end

function Editor:delete()
  if self.cursor >= #self.buffer then return end
  self.buffer = self.buffer:sub(1, self.cursor)
    .. self.buffer:sub(self.cursor + 2)
end

function Editor:kill_to_start()
  self.buffer = self.buffer:sub(self.cursor + 1)
  self.cursor = 0
end

function Editor:kill_to_end()
  self.buffer = self.buffer:sub(1, self.cursor)
end

function Editor:kill_prev_word()
  local target = prev_word(self.buffer, self.cursor)
  self.buffer = self.buffer:sub(1, target) .. self.buffer:sub(self.cursor + 1)
  self.cursor = target
end

function Editor:kill_next_word()
  local target = next_word(self.buffer, self.cursor, #self.buffer)
  self.buffer = self.buffer:sub(1, self.cursor) .. self.buffer:sub(target + 1)
end

-- ------------------------------------------------------------ key handling

--- handle one key press.
-- `key` is a norns keycode string ('LEFT', 'BACKSPACE', 'A', …) and `mods` is
-- a table of booleans { shift, ctrl, alt }. Returns true if the key was used,
-- so the caller can fall through to its own bindings.
function Editor:key(key, mods)
  local ctrl, alt, shift = mods.ctrl, mods.alt, mods.shift
  local plain = not ctrl and not alt

  -- motion
  if (plain and key == 'LEFT') or (ctrl and key == 'B') then
    if self.cursor > 0 then self.cursor = self.cursor - 1 end
  elseif (plain and key == 'RIGHT') or (ctrl and key == 'F') then
    if self.cursor < #self.buffer then self.cursor = self.cursor + 1 end
  elseif (plain and key == 'HOME') or (ctrl and key == 'A') then
    self.cursor = 0
  elseif (plain and key == 'END') or (ctrl and key == 'E') then
    self.cursor = #self.buffer
  elseif (ctrl and key == 'LEFT') or (alt and key == 'B') then
    self.cursor = prev_word(self.buffer, self.cursor)
  elseif (ctrl and key == 'RIGHT') or (alt and key == 'F') then
    self.cursor = next_word(self.buffer, self.cursor, #self.buffer)

  -- deletion. note shift-backspace and shift-delete kill to the line ends,
  -- which is why the shift variants are tested before the plain ones.
  elseif (shift and key == 'BACKSPACE') or (ctrl and key == 'U') then
    self:kill_to_start()
  elseif (shift and key == 'DELETE') or (ctrl and key == 'K') then
    self:kill_to_end()
  elseif (alt and key == 'BACKSPACE') or (ctrl and key == 'W') then
    self:kill_prev_word()
  elseif alt and key == 'D' then
    self:kill_next_word()
  elseif (plain and key == 'BACKSPACE') or (ctrl and key == 'H') then
    self:backspace()
  elseif (plain and key == 'DELETE') or (ctrl and key == 'D') then
    self:delete()

  -- clipboard
  elseif (ctrl or alt) and key == 'X' then
    M.clipboard = self.buffer
    self:set('')
  elseif (ctrl or alt) and key == 'C' then
    M.clipboard = self.buffer
  elseif (ctrl or alt) and key == 'V' then
    self:set(M.clipboard)

  else
    return false          -- not ours; printable characters arrive via :char()
  end
  return true
end

--- handle a printable character.
-- Teletype is upper-case only, so this folds the case rather than making the
-- user hold shift for every op name.
function Editor:char(ch)
  if #ch ~= 1 then return false end
  return self:insert(ch:upper())
end

return M
