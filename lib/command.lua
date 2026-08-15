-- command.lua
--
-- The parsed form of a single line of teletype. Port of
-- teletype/src/command.h + command.c.
--
-- Deliberately not an AST: teletype stores a flat array of at most 16 tagged
-- int16 words and evaluates it as a stack machine. Keeping the same shape
-- means the evaluator, the validator and the unparser all transcribe directly
-- from the C, and it is what the scene file format round-trips through.

local helpers = require 'helpers'

local M = {}

M.COMMAND_MAX_LENGTH = 16

-- tele_word_t. string tags rather than integers: they cost nothing here and
-- make both fixtures and stack traces readable.
M.NUMBER  = 'NUMBER'
M.XNUMBER = 'XNUMBER'
M.BNUMBER = 'BNUMBER'
M.RNUMBER = 'RNUMBER'
M.OP      = 'OP'
M.MOD     = 'MOD'
M.PRE_SEP = 'PRE_SEP'
M.SUB_SEP = 'SUB_SEP'

M.is_number = {
  [M.NUMBER] = true, [M.XNUMBER] = true,
  [M.BNUMBER] = true, [M.RNUMBER] = true,
}

--- a fresh empty command.
-- `data` is 1-indexed (lua convention) even though the C is 0-indexed; every
-- consumer in this port uses the lua indexing consistently.
function M.new()
  return { length = 0, separator = -1, data = {}, comment = false }
end

--- deep copy. teletype/src/command.c:9
function M.copy(src)
  local dst = { length = src.length, separator = src.separator,
                comment = src.comment, data = {} }
  for i = 1, src.length do
    dst.data[i] = { tag = src.data[i].tag, value = src.data[i].value }
  end
  return dst
end

--- extract the POST part of a command with a PRE separator.
-- teletype/src/command.c:14. the MOD at index 0 receives this and decides
-- whether and how often to run it. separator is a 0-based index in the C, so
-- the first POST word is at lua index separator + 2.
function M.copy_post(src)
  local dst = { length = src.length - src.separator - 1, separator = -1,
                comment = false, data = {} }
  for i = 1, dst.length do
    local s = src.data[src.separator + 1 + i]
    dst.data[i] = { tag = s.tag, value = s.value }
  end
  return dst
end

--- render a command back to canonical source text.
-- teletype/src/command.c:21. this is what the scene serializer writes, so it
-- must match byte for byte -- note that separators absorb the preceding space,
-- giving "IF X: P.NEXT" rather than "IF X : P.NEXT".
function M.print(cmd, op_names, mod_names)
  local out = {}
  for i = 1, cmd.length do
    local w = cmd.data[i]
    local tag, value = w.tag, w.value

    if tag == M.OP then
      out[#out + 1] = op_names[value]
    elseif tag == M.MOD then
      out[#out + 1] = mod_names[value]
    elseif tag == M.NUMBER then
      out[#out + 1] = tostring(value)
    elseif tag == M.XNUMBER then
      out[#out + 1] = helpers.itoa_hex(value)
    elseif tag == M.BNUMBER then
      out[#out + 1] = helpers.itoa_bin(value)
    elseif tag == M.RNUMBER then
      out[#out + 1] = helpers.itoa_rbin(value)
    elseif tag == M.PRE_SEP then
      out[#out + 1] = ':'
    elseif tag == M.SUB_SEP then
      out[#out + 1] = ';'
    end

    if i < cmd.length then
      local next_tag = cmd.data[i + 1].tag
      if next_tag ~= M.PRE_SEP and next_tag ~= M.SUB_SEP then
        out[#out + 1] = ' '
      end
    end
  end
  return table.concat(out)
end

return M
