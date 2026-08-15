-- ops/registry.lua
--
-- The op and mod tables, equivalent to tele_ops[] / tele_mods[] in
-- teletype/src/ops/op.c.
--
-- Every one of the 958 op names is registered, not just the ones this port
-- implements. That matters for scene compatibility: a scene written on
-- hardware that mentions TO.CV or JF.NOTE must still *parse*, validate and
-- round-trip through the editor identically, even on a norns with no telex or
-- just friends attached. Out-of-scope ops are registered with the correct
-- arity but a stub body, so they consume their arguments and push 0 rather
-- than corrupting the stack.
--
-- Implementations are attached later by lib/ops/*.lua via registry.impl().

local manifest = require 'ops.manifest'

local M = {}

M.ops = {}          -- index -> { name, params, returns, get, set, category }
M.by_name = {}      -- name  -> index
M.op_names = {}     -- index -> name  (for command.print)

M.mods = {}         -- index -> { name, params, func, category }
M.mod_by_name = {}
M.mod_names = {}

-- A stub for an op we deliberately do not implement. It still has to behave
-- like an op arithmetically: pop `params` arguments, push a result if the op
-- returns one. Anything else desynchronises the value stack and turns a
-- harmless unsupported op into a corrupted line.
local function make_stub(name, params, returns)
  return function(_, _, cs)
    for _ = 1, params do cs:pop() end
    if returns then cs:push(0) end
  end
end

for i, entry in ipairs(manifest.ops) do
  local name, params, returns, has_set, category =
    entry[1], entry[2], entry[3], entry[4], entry[5]
  M.ops[i] = {
    name = name,
    params = params,
    returns = returns,
    category = category,
    in_scope = manifest.in_scope[category] or false,
    -- `declares_set` records that the reference op has a setter, which the
    -- coverage test checks. `set` stays nil until an implementation supplies
    -- one, because the evaluator's get/set dispatch keys off `set ~= nil`.
    declares_set = has_set,
    get = make_stub(name, params, returns),
    set = nil,
    implemented = false,
  }
  M.by_name[name] = i
  M.op_names[i] = name
end

for i, entry in ipairs(manifest.mods) do
  local name, params, category = entry[1], entry[2], entry[3]
  M.mods[i] = {
    name = name,
    params = params,
    category = category,
    in_scope = manifest.in_scope[category] or false,
    -- a stub mod drops its arguments and does not run the POST
    func = function(_, _, cs)
      for _ = 1, params do cs:pop() end
    end,
    implemented = false,
  }
  M.mod_by_name[name] = i
  M.mod_names[i] = name
end

--- attach an implementation to an op.
-- `get` and `set` take (ss, es, cs) -- the scene state, exec state and the
-- current value stack, mirroring the C signature minus the `data` pointer,
-- which lua closures replace.
function M.impl(name, get, set)
  local i = M.by_name[name]
  if not i then error('unknown op: ' .. tostring(name), 2) end
  local op = M.ops[i]
  op.get = get
  op.set = set
  op.implemented = true
  return op
end

--- attach an implementation to a mod.
-- `func` takes (ss, es, cs, post_command).
function M.impl_mod(name, func)
  local i = M.mod_by_name[name]
  if not i then error('unknown mod: ' .. tostring(name), 2) end
  local mod = M.mods[i]
  mod.func = func
  mod.implemented = true
  return mod
end

--- resolve a token to an op or mod. used by the tokenizer.
-- returns tag ('OP'/'MOD') and index, or nil.
function M.lookup(token)
  local i = M.by_name[token]
  if i then return 'OP', i end
  i = M.mod_by_name[token]
  if i then return 'MOD', i end
  return nil
end

return M
