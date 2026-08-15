-- tokenizer.lua
--
-- Port of teletype/src/scanner.rl + match_token.rl.
--
-- The C uses two Ragel machines. The scanner splits a line into tokens and
-- separators; match_token then resolves one token, and critically requires
-- that the token match *completely and as exactly one rule*
-- (`no_of_tokens != 1` fails). That last condition is what makes a plain hash
-- lookup on the whole token equivalent here: a longest-match machine that must
-- consume the entire input in a single token is an anchored full match. So
-- there is no ambiguity between "P" and "P.N" to resolve, and the only piece
-- of the C with no natural lua analogue disappears.

local command = require 'command'
local helpers = require 'helpers'
local int16 = require 'int16'
local registry = require 'ops.registry'

local M = {}

M.MAX_TOKEN_LENGTH = 32

-- error_t, teletype/src/teletype.h. names kept symbolic; the display strings
-- live in errors() below and match tele_error() exactly.
M.E_OK = 'E_OK'
M.E_PARSE = 'E_PARSE'
M.E_LENGTH = 'E_LENGTH'
M.E_NEED_SPACE_PRE_SEP = 'E_NEED_SPACE_PRE_SEP'
M.E_NEED_SPACE_SUB_SEP = 'E_NEED_SPACE_SUB_SEP'

local ERROR_TEXT = {
  E_OK = 'OK',
  E_PARSE = 'UNKNOWN WORD',
  E_LENGTH = 'COMMAND TOO LONG',
  E_NEED_PARAMS = 'NOT ENOUGH PARAMS',
  E_EXTRA_PARAMS = 'TOO MANY PARAMS',
  E_NO_MOD_HERE = 'MOD NOT ALLOWED HERE',
  E_MANY_PRE_SEP = 'EXTRA PRE SEPARATOR',
  E_NEED_PRE_SEP = 'NEED PRE SEPARATOR',
  E_PLACE_PRE_SEP = 'BAD PRE SEPARATOR',
  E_NO_SUB_SEP_IN_PRE = 'NO SUB SEP IN PRE',
  E_NOT_LEFT = 'MOVE LEFT',
  E_NEED_SPACE_PRE_SEP = 'NEED SPACE AFTER :',
  E_NEED_SPACE_SUB_SEP = 'NEED SPACE AFTER ;',
}

--- human-readable text for an error code. teletype/src/teletype.c:402
function M.error_text(err)
  return ERROR_TEXT[err] or 'UNKNOWN ERROR'
end

-- ------------------------------------------------------------- number tokens

--- C strtol, faithfully enough for the inputs the lexer admits.
-- Two behaviours here are load-bearing and easy to miss:
--   * base 0 means "auto-detect", so a leading zero selects *octal*. teletype
--     passes base 0 for plain decimals, which is why "010" is 8 and "099" is 0.
--   * parsing stops at the first character that is not a digit in the base,
--     returning what it has (0 if that is nothing).
local function strtol(s, base)
  local i, sign = 1, 1
  if s:sub(i, i) == '-' then sign = -1; i = i + 1
  elseif s:sub(i, i) == '+' then i = i + 1 end

  if base == 0 then
    if s:sub(i, i) == '0' then
      if s:sub(i + 1, i + 1):upper() == 'X' then base = 16; i = i + 2
      else base = 8; i = i + 1 end
    else
      base = 10
    end
  end

  local value, digits = 0, 0
  while i <= #s do
    local d = tonumber(s:sub(i, i), base)
    if not d then break end
    value = value * base + d
    digits = digits + 1
    i = i + 1
  end
  if digits == 0 then return 0 end
  return sign * value
end

-- match_token.rl:14
--   number = (('-')? [0-9]+) | ([X] [0-9A-F]+) | ([B|R] [0-1]+);
--
-- Note [B|R] is a Ragel character *class*, so it admits '|' as well as 'B' and
-- 'R'. So "|101" lexes as a number -- but MATCH_NUMBER only special-cases the
-- prefix by testing token[0] against 'X'/'B'/'R', so '|' falls through to the
-- base-0 strtol path and yields NUMBER:0 rather than a binary value. Almost
-- certainly unintended upstream, but it is observable, so it is reproduced.
local function match_number(token)
  local lexes =
    token:match('^%-?%d+$')
    or token:match('^X[0-9A-F]+$')
    or token:match('^[B|R][01]+$')
  if not lexes then return nil end

  -- transcribed from the MATCH_NUMBER macro, match_token.rl:1119
  local tag, base, binhex, bitrev = command.NUMBER, 0, false, false
  local body = token
  local prefix = token:sub(1, 1)

  if prefix == 'X' then
    tag, binhex, base, body = command.XNUMBER, true, 16, token:sub(2)
  elseif prefix == 'B' then
    tag, binhex, base, body = command.BNUMBER, true, 2, token:sub(2)
  elseif prefix == 'R' then
    tag, binhex, bitrev, base, body =
      command.RNUMBER, true, true, 2, token:sub(2)
  end

  local value = strtol(body, base)
  -- `if (binhex) val = (int16_t)((uint16_t)val)` -- truncate then reinterpret
  if binhex then value = int16.from_u16(value) end
  -- bitrev discards the strtol result entirely
  if bitrev then value = helpers.rev_bitstring_to_int(body) end

  -- the C assigns strtol's long into an int32_t before clamping to int16
  value = value & 0xffffffff
  if value >= 0x80000000 then value = value - 0x100000000 end

  return tag, int16.clamp(value)
end

--- resolve a single token to a tagged word. match_token.rl:1154
-- returns tag, value or nil if the token matches nothing.
function M.match_token(token)
  local tag, value = match_number(token)
  if tag then return tag, value end

  local kind, index = registry.lookup(token)
  if kind == 'OP' then return command.OP, index end
  if kind == 'MOD' then return command.MOD, index end

  return nil
end

-- ------------------------------------------------------------------ scanner

local SEPARATORS = { [' '] = true, ['\n'] = true, ['\t'] = true }

--- tokenize a line into a command.
-- port of scanner() in teletype/src/scanner.rl. returns cmd, err, err_msg.
--
-- the input is expected to be uppercased already, as it is everywhere in
-- teletype (the editor uppercases keystrokes, the scene deserializer
-- toupper()s the whole file).
function M.parse(line)
  local cmd = command.new()
  local i, n = 1, #line

  -- append a word, applying the same overflow rule as the C: length is
  -- incremented first and then compared, so a 16th word is an error and the
  -- effective maximum is 15 words.
  local function push(tag, value)
    cmd.length = cmd.length + 1
    cmd.data[cmd.length] = { tag = tag, value = value }
    if cmd.length >= command.COMMAND_MAX_LENGTH then return M.E_LENGTH end
    return nil
  end

  while i <= n do
    local c = line:sub(i, i)

    if SEPARATORS[c] then
      i = i + 1
    elseif c == ':' then
      -- ": " is a PRE separator; a bare ':' is an error
      if line:sub(i + 1, i + 1) ~= ' ' then
        return nil, M.E_NEED_SPACE_PRE_SEP, ''
      end
      cmd.separator = cmd.length  -- 0-based index, as in the C
      local err = push(command.PRE_SEP, 0)
      if err then return nil, err, '' end
      i = i + 2
    elseif c == ';' then
      if line:sub(i + 1, i + 1) ~= ' ' then
        return nil, M.E_NEED_SPACE_SUB_SEP, ''
      end
      local err = push(command.SUB_SEP, 0)
      if err then return nil, err, '' end
      i = i + 2
    else
      -- a token runs until whitespace, ':' or ';' -- the Ragel `--` operator
      -- excludes those from the token body entirely
      local start = i
      while i <= n do
        local ch = line:sub(i, i)
        if SEPARATORS[ch] or ch == ':' or ch == ';' then break end
        i = i + 1
      end
      local token = line:sub(start, i - 1)
      if #token > M.MAX_TOKEN_LENGTH then
        token = token:sub(1, M.MAX_TOKEN_LENGTH)
      end

      local tag, value = M.match_token(token)
      if not tag then return nil, M.E_PARSE, token end

      local err = push(tag, value)
      if err then return nil, err, '' end
    end
  end

  return cmd, M.E_OK, ''
end

--- render a command back to text, resolving op/mod indices to names.
function M.print(cmd)
  return command.print(cmd, registry.op_names, registry.mod_names)
end

return M
