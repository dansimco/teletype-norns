-- scene.lua -- the Teletype scene file format
-- port of teletype/src/scene_serialization.c
--
-- This is the interchange format: the same .txt a hardware Teletype writes to
-- a USB stick. Getting it byte-exact is what lets a scene move between the
-- module and norns, so both directions are diffed against the C for every one
-- of the reference presets.
--
-- Layout, in order:
--   * up to 32 lines x 32 chars of description text
--   * `#1`..`#8`, `#M`, `#I`, each followed by its (re-printed) command lines
--   * `#P` -- four tab-separated columns: len, wrap, start, end, then 64 rows
--     of values
--   * `#G` -- 256 grid button states, then 64 fader values
--
-- Grid ops are out of scope for this port, but the `#G` block is still parsed
-- and written back so a scene edited here keeps its grid config when it
-- returns to hardware.

local command = require 'command'
local st = require 'state'
local tokenizer = require 'tokenizer'
local validate = require 'validate'

local M = {}

M.SCENE_TEXT_LINES = 32
M.SCENE_TEXT_CHARS = 32
local GRID_BUTTON_COUNT = 256
local GRID_FADER_COUNT = 64

--- empty description text
function M.new_text()
  local t = {}
  for i = 0, M.SCENE_TEXT_LINES - 1 do t[i] = '' end
  return t
end

--- default grid data, for scenes that have no #G block
function M.new_grid()
  local g = { button = {}, fader = {} }
  for i = 0, GRID_BUTTON_COUNT - 1 do g.button[i] = 0 end
  for i = 0, GRID_FADER_COUNT - 1 do g.fader[i] = 0 end
  return g
end

-- ---------------------------------------------------------------- serialize

--- render a scene to the .txt format. returns a string.
-- `text` is the description (0-indexed lines), `grid` the #G data; both
-- default to empty.
function M.serialize(ss, text, grid)
  text = text or M.new_text()
  grid = grid or ss.grid or M.new_grid()
  local out = {}
  local function w(s) out[#out + 1] = s end

  -- description: runs of blank lines collapse to a single newline
  local blank = false
  for l = 0, M.SCENE_TEXT_LINES - 1 do
    local line = text[l] or ''
    if #line > 0 then
      w(line); w('\n')
      blank = false
    elseif not blank then
      w('\n')
      blank = true
    end
  end

  -- scripts
  for s = 0, st.EDITABLE_SCRIPT_COUNT - 1 do
    w('\n\n#')
    if s == st.METRO_SCRIPT then w('M')
    elseif s == st.INIT_SCRIPT then w('I')
    else w(string.char(s + 49)) end        -- '1'..'8'
    for l = 0, ss:script_len(s) - 1 do
      w('\n')
      w(tokenizer.print(ss:script_command(s, l)))
    end
  end

  -- patterns: four header rows then 64 value rows, tab separated
  w('\n\n#P\n')
  local function row(get)
    for b = 0, 3 do
      w(tostring(get(b)))
      w(b == 3 and '\n' or '\t')
    end
  end
  row(function(b) return ss.patterns[b].len end)
  row(function(b) return ss.patterns[b].wrap end)
  row(function(b) return ss.patterns[b].start end)
  row(function(b) return ss.patterns[b]['end'] end)
  w('\n')
  for l = 0, st.PATTERN_LENGTH - 1 do
    row(function(b) return ss.patterns[b].val[l] end)
  end

  -- grid
  w('\n#G\n')
  for i = 0, GRID_BUTTON_COUNT - 1 do
    w(tostring(grid.button[i] or 0))
    if (i & 15) == 15 then w('\n') end
  end
  w('\n')
  for i = 0, GRID_FADER_COUNT - 1 do
    w(tostring(grid.fader[i] or 0))
    w((i & 15) == 15 and '\n' or '\t')
  end

  return table.concat(out)
end

-- -------------------------------------------------------------- deserialize

local STATE = {
  DESC = 0, POUND = 1, POUND_IGNORE = 2, SCRIPT = 3, PATTERNS = 4,
  GRID = 5, DONE = 6,
}

--- parse a .txt scene into `ss`. returns text, grid, warnings.
-- Character-at-a-time, mirroring the C state machine, because the format is
-- not line-regular: `#P` rows and `#G` rows are counted, not labelled.
function M.deserialize(source, ss)
  local text = M.new_text()
  local grid = M.new_grid()
  local warnings = {}

  local c = '\n'
  local prev_cr = false
  local new_line
  local l, p = 0, 0
  local s, s2 = STATE.DESC, STATE.DESC
  local script = st.NO_SCRIPT
  local b = 0
  local num, neg = 0, 1
  local input = {}
  local grid_state, grid_count, grid_num = 0, 0, 0

  local pos, len = 1, #source
  while pos <= len do
    new_line = (c == '\n')
    c = source:sub(pos, pos):upper()
    pos = pos + 1

    -- normalise DOS / classic-Mac / unix line endings
    if c == '\r' then
      c = '\n'
      prev_cr = true
    elseif c == '\n' and prev_cr then
      prev_cr = false
      goto continue
    else
      prev_cr = false
    end

    if c == '#' and new_line then
      s = STATE.POUND
      goto continue
    end

    if s == STATE.DESC then
      if c == '\n' then
        l = l + 1
        p = 0
      elseif l < M.SCENE_TEXT_LINES and p < M.SCENE_TEXT_CHARS then
        text[l] = text[l] .. c
        p = p + 1
      end

    elseif s == STATE.POUND then
      if c == 'M' then
        script = st.METRO_SCRIPT; s2 = STATE.SCRIPT
      elseif c == 'I' then
        script = st.INIT_SCRIPT; s2 = STATE.SCRIPT
      elseif c == 'P' then
        s2 = STATE.PATTERNS
      elseif c == 'G' then
        grid_state, grid_count = 0, 0
        s2 = STATE.GRID
      else
        script = c:byte() - 49          -- '1' is script 0
        if script < 0 or script >= st.EDITABLE_SCRIPT_COUNT then
          script = st.NO_SCRIPT
        end
        s2 = STATE.SCRIPT
      end
      l, p = 0, 0
      s = STATE.POUND_IGNORE

    elseif s == STATE.POUND_IGNORE then
      -- skip the rest of the header line
      if c == '\n' then s = s2 end

    elseif s == STATE.SCRIPT then
      if script ~= st.NO_SCRIPT and script >= 0
          and script < st.EDITABLE_SCRIPT_COUNT then
        if c ~= '\n' then
          if p < 32 then
            p = p + 1
            input[p] = c
          end
        elseif p > 0 and l < st.SCRIPT_MAX_COMMANDS then
          local line = table.concat(input, '', 1, p)
          local cmd, perr = tokenizer.parse(line)
          if perr ~= 'E_OK' then
            warnings[#warnings + 1] = ('%s: %s'):format(
              tokenizer.error_text(perr), line)
          else
            local verr = validate.validate(cmd)
            if verr ~= 'E_OK' then
              warnings[#warnings + 1] = ('%s: %s'):format(
                tokenizer.error_text(verr), line)
            else
              ss:overwrite_script_command(script, l, cmd)
              l = l + 1
            end
          end
          input = {}
          p = 0
        end
      end

    elseif s == STATE.PATTERNS then
      if c == '\n' or c == '\t' then
        if b < 4 then
          local value = neg * num
          if l > 3 then
            ss.patterns[b].val[l - 4] = value
          elseif l == 0 then ss.patterns[b].len = value
          elseif l == 1 then ss.patterns[b].wrap = value
          elseif l == 2 then ss.patterns[b].start = value
          elseif l == 3 then ss.patterns[b]['end'] = value
          end
        end
        b = b + 1
        num, neg = 0, 1
        if c == '\n' then
          if p > 0 then l = l + 1 end
          -- four header rows plus 64 values, then the block is finished
          if l > 68 then s = STATE.DONE end
          b, p = 0, 0
        end
      else
        if c == '-' then neg = -1
        elseif c >= '0' and c <= '9' then num = num * 10 + (c:byte() - 48) end
        p = p + 1
      end

    elseif s == STATE.GRID then
      if grid_state == 0 then
        if c >= '0' and c <= '9' then
          grid.button[grid_count] = (c ~= '0') and 1 or 0
          grid_count = grid_count + 1
          if grid_count >= GRID_BUTTON_COUNT then
            grid_count, grid_state = 0, 1
          end
        end
      elseif grid_state == 1 then
        if c >= '0' and c <= '9' then
          grid_num = c:byte() - 48
          grid_state = 2
        end
      elseif grid_state == 2 then
        if c >= '0' and c <= '9' then
          grid_num = grid_num * 10 + (c:byte() - 48)
        elseif c == '\t' or c == '\n' then
          if grid_count < GRID_FADER_COUNT then
            grid.fader[grid_count] = grid_num
            grid_num = 0
            grid_count = grid_count + 1
          end
        end
      end
    end

    ::continue::
  end

  return text, grid, warnings
end

-- ------------------------------------------------------------------ files

function M.read_file(path, ss)
  local f = io.open(path, 'rb')
  if not f then return nil, ('cannot open %s'):format(path) end
  local source = f:read('a')
  f:close()
  return M.deserialize(source, ss)
end

function M.write_file(path, ss, text, grid)
  local f = io.open(path, 'wb')
  if not f then return false, ('cannot write %s'):format(path) end
  f:write(M.serialize(ss, text, grid))
  f:close()
  return true
end

return M
