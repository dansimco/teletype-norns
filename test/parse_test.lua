-- parse_test.lua
--
-- Diffs the lua tokenizer + validator against the real teletype C core over
-- test/fixtures/parse_corpus.txt. Every record checks four things at once:
-- the parse error, the word array, the validate error, and the unparse.
--
-- fixture record layout (from lib/tools/oracle/oracle.c mode_parse):
--   1 "line" | 2 input | 3 parse_err | 4 parse_msg | 5 words
--   6 separator | 7 validate_err | 8 validate_msg | 9 printed

local H = require 'harness'
local command = require 'command'
local registry = require 'ops.registry'
local tokenizer = require 'tokenizer'
local validate = require 'validate'

-- render our parsed command in the oracle's word notation, so the two can be
-- compared as plain strings
local function words_of(cmd)
  local parts = {}
  for i = 1, cmd.length do
    local w = cmd.data[i]
    if w.tag == command.OP then
      parts[i] = 'OP:' .. registry.op_names[w.value]
    elseif w.tag == command.MOD then
      parts[i] = 'MOD:' .. registry.mod_names[w.value]
    else
      parts[i] = w.tag .. ':' .. w.value
    end
  end
  return table.concat(parts, ',')
end

H.suite('parse: lua vs teletype C oracle', function()
  local records = H.fixture('test/fixtures/parse.tsv')

  H.test('corpus is non-trivial', function()
    H.ok(#records > 2000, ('only %d records'):format(#records))
  end)

  H.test('parse error codes match', function()
    for _, line in ipairs(records) do
      local f = H.split_tsv(line)
      local input, want_err = f[2], f[3]
      local _, got_err = tokenizer.parse(input:upper())
      H.eq(got_err, want_err, ('parse error for %q'):format(input))
    end
  end)

  H.test('parse error messages match', function()
    for _, line in ipairs(records) do
      local f = H.split_tsv(line)
      local input, want_err, want_msg = f[2], f[3], f[4]
      local _, got_err, got_msg = tokenizer.parse(input:upper())
      if got_err == want_err and want_err ~= 'E_OK' then
        H.eq(got_msg, want_msg, ('parse message for %q'):format(input))
      end
    end
  end)

  H.test('word arrays match', function()
    for _, line in ipairs(records) do
      local f = H.split_tsv(line)
      local input, want_err, want_words = f[2], f[3], f[5]
      local cmd, got_err = tokenizer.parse(input:upper())
      if want_err == 'E_OK' and got_err == 'E_OK' then
        H.eq(words_of(cmd), want_words, ('words for %q'):format(input))
      end
    end
  end)

  H.test('separator positions match', function()
    for _, line in ipairs(records) do
      local f = H.split_tsv(line)
      local input, want_err, want_sep = f[2], f[3], f[6]
      local cmd, got_err = tokenizer.parse(input:upper())
      if want_err == 'E_OK' and got_err == 'E_OK' then
        H.eq(cmd.separator, tonumber(want_sep),
          ('separator for %q'):format(input))
      end
    end
  end)

  H.test('validate error codes match', function()
    for _, line in ipairs(records) do
      local f = H.split_tsv(line)
      local input, want_err, want_verr = f[2], f[3], f[7]
      local cmd, got_err = tokenizer.parse(input:upper())
      if want_err == 'E_OK' and got_err == 'E_OK' then
        local got_verr = validate.validate(cmd)
        H.eq(got_verr, want_verr, ('validate error for %q'):format(input))
      end
    end
  end)

  H.test('validate error messages match', function()
    for _, line in ipairs(records) do
      local f = H.split_tsv(line)
      local input, want_err, want_verr, want_vmsg = f[2], f[3], f[7], f[8]
      local cmd, got_err = tokenizer.parse(input:upper())
      if want_err == 'E_OK' and got_err == 'E_OK' then
        local got_verr, got_vmsg = validate.validate(cmd)
        if got_verr == want_verr and want_verr ~= 'E_OK' then
          H.eq(got_vmsg, want_vmsg, ('validate message for %q'):format(input))
        end
      end
    end
  end)

  H.test('unparse round-trips identically', function()
    for _, line in ipairs(records) do
      local f = H.split_tsv(line)
      local input, want_err, want_verr, want_printed = f[2], f[3], f[7], f[9]
      local cmd, got_err = tokenizer.parse(input:upper())
      if want_err == 'E_OK' and got_err == 'E_OK' and want_verr == 'E_OK' then
        H.eq(tokenizer.print(cmd), want_printed,
          ('unparse of %q'):format(input))
      end
    end
  end)
end)
