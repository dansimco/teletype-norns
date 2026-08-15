-- gen_manifest.lua
--
-- Builds lib/ops/manifest.lua: the authoritative name / arity / category list
-- for every teletype op and mod.
--
-- Two inputs, because neither alone has everything:
--   test/fixtures/ops.tsv  -- name, params, returns, has_set, in tele_ops[]
--                             order (from lib/tools/oracle, i.e. the real tables)
--   teletype/src/ops/op.c  -- the `// category` comments delimiting that array
--
-- The two are zipped by index, which is safe because the oracle walks
-- tele_ops[] in the same order op.c declares it.
--
-- usage: lua5.4 lib/tools/gen_manifest.lua

local TSV = 'test/fixtures/ops.tsv'
local OPC = '../teletype/src/ops/op.c'
local OUT = 'lib/ops/manifest.lua'

-- which categories the norns port implements in v1. see the plan: the language
-- core plus the three families we can actually drive from norns.
local IN_SCOPE = {
  variables = true, init = true, turtle = true, metronome = true,
  patterns = true, queue = true, hardware = true, maths = true,
  stack = true, controlflow = true, delay = true, seed = true,
  ansible = true, midi_in = true, i2c = true,
}

-- ---------------------------------------------------------------- parse op.c

-- returns two ordered arrays of category names, one entry per array slot
local function categories()
  local src = assert(io.open(OPC)):read('a')

  local function scan(header)
    local body = src:match(header .. '%s*=%s*{(.-)\n};')
    assert(body, 'could not find ' .. header)
    local cats, current = {}, 'unknown'
    for line in body:gmatch('[^\n]+') do
      local comment = line:match('^%s*//%s*(.+)%s*$')
      if comment then
        -- normalise "disting ex" / "ER301" / "W/S" into table-friendly keys
        current = comment:lower():gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')
      else
        -- note [%w_]: lua's %w excludes underscore, and every symbol here has one
        for name in line:gmatch('&([%w_]+)') do
          -- the MI.* block trails the seed section with no comment of its own
          local cat = name:match('^op_MI_') and 'midi_in' or current
          cats[#cats + 1] = cat
        end
      end
    end
    return cats
  end

  return scan('const tele_op_t %*tele_ops%[E_OP__LENGTH%]'),
         scan('const tele_mod_t %*tele_mods%[E_MOD__LENGTH%]')
end

-- ----------------------------------------------------------------- read tsv

local ops, mods = {}, {}
for line in io.lines(TSV) do
  local f = {}
  for field in line:gmatch('[^\t]+') do f[#f + 1] = field end
  if f[1] == 'op' then
    ops[#ops + 1] = {
      name = f[2], params = tonumber(f[3]),
      returns = f[4] == '1', has_set = f[5] == '1',
    }
  elseif f[1] == 'mod' then
    mods[#mods + 1] = { name = f[2], params = tonumber(f[3]) }
  end
end

local op_cats, mod_cats = categories()
assert(#op_cats == #ops,
  ('op count mismatch: op.c has %d, oracle has %d'):format(#op_cats, #ops))
assert(#mod_cats == #mods,
  ('mod count mismatch: op.c has %d, oracle has %d'):format(#mod_cats, #mods))

for i, o in ipairs(ops) do o.category = op_cats[i] end
for i, m in ipairs(mods) do m.category = mod_cats[i] end

-- ------------------------------------------------------------------- emit

local out = {}
local function emit(s) out[#out + 1] = s end

local function q(s)
  -- op names contain quotes-hostile characters like \ and " is never present,
  -- but %q handles everything uniformly
  return string.format('%q', s)
end

emit([[
-- manifest.lua -- GENERATED, do not edit by hand.
--
-- Every op and mod in teletype v5.0.0, with its arity and category, extracted
-- from the real tele_ops[]/tele_mods[] tables. This is the contract the port
-- is checked against: test/coverage_test.lua asserts that every in-scope entry
-- here is implemented with matching arity, and that nothing is implemented
-- that isn't here.
--
-- regenerate with:
--   make -C lib/tools/oracle && ./lib/tools/oracle/oracle ops > test/fixtures/ops.tsv
--   lua5.4 lib/tools/gen_manifest.lua

local M = {}

-- categories the norns port implements; everything else is out of scope for
-- now and lives behind the raw i2c transport.
M.in_scope = {
]])
local scope_names = {}
for k in pairs(IN_SCOPE) do scope_names[#scope_names + 1] = k end
table.sort(scope_names)
for _, k in ipairs(scope_names) do emit(('  %s = true,'):format(k)) end
emit('}')
emit('')

emit('-- { name, params, returns, has_set, category }')
emit('M.ops = {')
for _, o in ipairs(ops) do
  emit(('  { %s, %d, %s, %s, %s },'):format(
    q(o.name), o.params, tostring(o.returns), tostring(o.has_set), q(o.category)))
end
emit('}')
emit('')

emit('-- { name, params, category }')
emit('M.mods = {')
for _, m in ipairs(mods) do
  emit(('  { %s, %d, %s },'):format(q(m.name), m.params, q(m.category)))
end
emit('}')
emit('')

emit([[
--- look up an op entry by name.
function M.op(name)
  for _, o in ipairs(M.ops) do if o[1] == name then return o end end
end

--- look up a mod entry by name.
function M.mod(name)
  for _, m in ipairs(M.mods) do if m[1] == name then return m end end
end

return M]])

local f = assert(io.open(OUT, 'w'))
f:write(table.concat(out, '\n'), '\n')
f:close()

-- a quick census so the scope decision stays visible
local census, total_in = {}, 0
for _, o in ipairs(ops) do
  census[o.category] = (census[o.category] or 0) + 1
  if IN_SCOPE[o.category] then total_in = total_in + 1 end
end
local keys = {}
for k in pairs(census) do keys[#keys + 1] = k end
table.sort(keys, function(a, b) return census[a] > census[b] end)
print(('wrote %s: %d ops, %d mods'):format(OUT, #ops, #mods))
print(('in scope: %d ops'):format(total_in))
for _, k in ipairs(keys) do
  print(('  %-16s %4d  %s'):format(k, census[k], IN_SCOPE[k] and 'IN' or '--'))
end
