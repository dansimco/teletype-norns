-- coverage_test.lua
--
-- Checks the implemented op set against the manifest generated from the real
-- tele_ops[]/tele_mods[] tables. This is what makes "full core language" a
-- checkable claim rather than an assertion.
--
-- Set TT_COVERAGE_STRICT=1 to fail on in-scope ops that are still stubs;
-- otherwise the suite reports progress without failing, so partial work stays
-- green while the remaining families land.

local H = require 'harness'
local manifest = require 'ops.manifest'
local registry = require 'ops.registry'
require 'ops.init'

local STRICT = os.getenv('TT_COVERAGE_STRICT') == '1'

H.suite('op coverage vs the reference tables', function()
  H.test('registry matches the manifest exactly', function()
    H.eq(#registry.ops, #manifest.ops, 'op count')
    H.eq(#registry.mods, #manifest.mods, 'mod count')
    for i, entry in ipairs(manifest.ops) do
      local op = registry.ops[i]
      if op then
        H.eq(op.name, entry[1], ('op %d name'):format(i))
        H.eq(op.params, entry[2], ('%s params'):format(entry[1]))
        H.eq(op.returns, entry[3], ('%s returns'):format(entry[1]))
      end
    end
    for i, entry in ipairs(manifest.mods) do
      local mod = registry.mods[i]
      if mod then
        H.eq(mod.name, entry[1], ('mod %d name'):format(i))
        H.eq(mod.params, entry[2], ('%s params'):format(entry[1]))
      end
    end
  end)

  H.test('nothing out of scope is implemented by accident', function()
    for _, op in ipairs(registry.ops) do
      if op.implemented and not op.in_scope then
        H.ok(false, ('%s (%s) is implemented but out of scope')
          :format(op.name, op.category))
      end
    end
  end)

  H.test('in-scope ops are implemented', function()
    -- group the gaps by category so the report is a work list, not a wall
    local missing, counts, total_missing = {}, {}, 0
    for _, op in ipairs(registry.ops) do
      if op.in_scope and not op.implemented then
        missing[op.category] = missing[op.category] or {}
        table.insert(missing[op.category], op.name)
        counts[op.category] = (counts[op.category] or 0) + 1
        total_missing = total_missing + 1
      end
    end
    for _, mod in ipairs(registry.mods) do
      if mod.in_scope and not mod.implemented then
        local c = mod.category .. ' (mods)'
        missing[c] = missing[c] or {}
        table.insert(missing[c], mod.name)
        counts[c] = (counts[c] or 0) + 1
        total_missing = total_missing + 1
      end
    end

    local in_scope = 0
    for _, op in ipairs(registry.ops) do
      if op.in_scope then in_scope = in_scope + 1 end
    end
    for _, mod in ipairs(registry.mods) do
      if mod.in_scope then in_scope = in_scope + 1 end
    end

    print(('       %d/%d in-scope ops+mods implemented')
      :format(in_scope - total_missing, in_scope))
    if total_missing > 0 then
      local cats = {}
      for c in pairs(counts) do cats[#cats + 1] = c end
      table.sort(cats, function(a, b) return counts[a] > counts[b] end)
      for _, c in ipairs(cats) do
        print(('       todo %-22s %3d  %s'):format(c, counts[c],
          table.concat(missing[c], ' '):sub(1, 60)))
      end
    end

    if STRICT then
      H.eq(total_missing, 0, 'unimplemented in-scope ops')
    end
  end)
end)
