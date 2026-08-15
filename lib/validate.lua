-- validate.lua
--
-- Direct transcription of validate() in teletype/src/teletype.c:49.
--
-- A right-to-left abstract interpretation of the value stack: it never runs
-- anything, it just checks that the depth works out. Because the language is
-- evaluated right to left, so is this.

local command = require 'command'
local registry = require 'ops.registry'

local M = {}

M.E_OK = 'E_OK'
M.E_NEED_PARAMS = 'E_NEED_PARAMS'
M.E_EXTRA_PARAMS = 'E_EXTRA_PARAMS'
M.E_NO_MOD_HERE = 'E_NO_MOD_HERE'
M.E_MANY_PRE_SEP = 'E_MANY_PRE_SEP'
M.E_NEED_PRE_SEP = 'E_NEED_PRE_SEP'
M.E_PLACE_PRE_SEP = 'E_PLACE_PRE_SEP'
M.E_NO_SUB_SEP_IN_PRE = 'E_NO_SUB_SEP_IN_PRE'
M.E_NOT_LEFT = 'E_NOT_LEFT'

--- validate a parsed command. returns err, err_msg.
function M.validate(cmd)
  local stack_depth = 0
  local sep_count = 0

  -- walk words right to left. `idx` is 1-based here; the C is 0-based, so its
  -- `idx == 0` becomes `idx == 1`.
  for idx = cmd.length, 1, -1 do
    local word = cmd.data[idx]
    local tag, value = word.tag, word.value

    -- a "first_cmd" word is one that starts a command or sub-command
    local prev_tag = idx > 1 and cmd.data[idx - 1].tag or nil
    local first_cmd = (idx == 1)
      or prev_tag == command.PRE_SEP
      or prev_tag == command.SUB_SEP

    if command.is_number[tag] then
      stack_depth = stack_depth + 1

    elseif tag == command.OP then
      local op = registry.ops[value]

      -- an op that produces nothing can only stand in first position;
      -- anywhere else it would leave a hole in the argument list
      if not first_cmd and not op.returns then
        return M.E_NOT_LEFT, op.name
      end

      stack_depth = stack_depth - op.params
      if stack_depth < 0 then
        return M.E_NEED_PARAMS, op.name
      end
      if op.returns then stack_depth = stack_depth + 1 end

      -- in first position an op with a setter consumes one extra value.
      -- upstream notes this is technically wrong (it only gets away with it
      -- because idx is about to hit 0 and end the loop) -- kept as-is so the
      -- accepted/rejected sets match exactly.
      if first_cmd and op.declares_set then
        stack_depth = stack_depth - 1
      end

    elseif tag == command.MOD then
      local mod = registry.mods[value]
      local err
      if idx ~= 1 then
        err = M.E_NO_MOD_HERE
      elseif cmd.separator == -1 then
        err = M.E_NEED_PRE_SEP
      elseif stack_depth < mod.params then
        err = M.E_NEED_PARAMS
      elseif stack_depth > mod.params then
        err = M.E_EXTRA_PARAMS
      end
      if err then return err, mod.name end
      stack_depth = 0

    elseif tag == command.PRE_SEP then
      sep_count = sep_count + 1
      if sep_count > 1 then return M.E_MANY_PRE_SEP, '' end
      if idx == 1 then return M.E_PLACE_PRE_SEP, '' end
      if cmd.data[1].tag ~= command.MOD then return M.E_PLACE_PRE_SEP, '' end
      if stack_depth > 1 then return M.E_EXTRA_PARAMS, '' end
      stack_depth = 0

    elseif tag == command.SUB_SEP then
      if sep_count > 0 then return M.E_NO_SUB_SEP_IN_PRE, '' end
      if stack_depth > 1 then return M.E_EXTRA_PARAMS, '' end
      stack_depth = 0
    end
  end

  if stack_depth > 1 then return M.E_EXTRA_PARAMS, '' end
  return M.E_OK, ''
end

return M
