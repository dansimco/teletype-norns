-- harness.lua
--
-- A minimal test harness. norns ships LuaUnit, but these tests run on the dev
-- machine against the C oracle rather than on the device, and the bulk of them
-- are "diff thousands of records against a fixture" -- which wants compact
-- failure reporting far more than it wants an assertion library.

local H = {}

local suites = {}
local current

H.failures = 0
H.assertions = 0
H.tests = 0

--- declare a suite. `fn` registers tests by calling H.test().
function H.suite(name, fn)
  current = { name = name, tests = {} }
  suites[#suites + 1] = current
  fn()
  current = nil
end

function H.test(name, fn)
  assert(current, 'H.test outside a suite')
  current.tests[#current.tests + 1] = { name = name, fn = fn }
end

-- per-test failure accumulation, so one broken invariant across 2855 records
-- reports as a handful of examples plus a count, not 2855 lines of noise
local ctx

local function fail(msg)
  ctx.failed = ctx.failed + 1
  if #ctx.examples < 5 then ctx.examples[#ctx.examples + 1] = msg end
end

function H.ok(cond, msg)
  H.assertions = H.assertions + 1
  if not cond then fail(msg or 'assertion failed') end
  return cond
end

function H.eq(got, want, msg)
  H.assertions = H.assertions + 1
  if got ~= want then
    fail(('%s\n      want: %s\n      got:  %s'):format(
      msg or 'values differ', tostring(want), tostring(got)))
    return false
  end
  return true
end

--- split a tab-separated line, preserving empty fields.
-- gmatch('[^\t]+') silently drops them, which matters because the oracle
-- emits empty fields for "no error message" and "did not reach validate".
function H.split_tsv(line)
  local fields, pos = {}, 1
  while true do
    local sep = line:find('\t', pos, true)
    if not sep then
      fields[#fields + 1] = line:sub(pos)
      return fields
    end
    fields[#fields + 1] = line:sub(pos, sep - 1)
    pos = sep + 1
  end
end

--- read a fixture file line by line, erroring clearly if it is missing.
function H.fixture(path)
  local f = io.open(path)
  if not f then
    error(('missing fixture %s -- run `make fixtures`'):format(path), 2)
  end
  local lines = {}
  for line in f:lines() do lines[#lines + 1] = line end
  f:close()
  return lines
end

function H.run()
  local t0 = os.clock()
  for _, suite in ipairs(suites) do
    print('\n' .. suite.name)
    for _, test in ipairs(suite.tests) do
      ctx = { failed = 0, examples = {} }
      H.tests = H.tests + 1
      local ok, err = pcall(test.fn)
      if not ok then
        ctx.failed = ctx.failed + 1
        ctx.examples[#ctx.examples + 1] = 'error: ' .. tostring(err)
      end
      if ctx.failed == 0 then
        print(('  ok   %s'):format(test.name))
      else
        H.failures = H.failures + ctx.failed
        print(('  FAIL %s  (%d failures)'):format(test.name, ctx.failed))
        for _, e in ipairs(ctx.examples) do
          print('    - ' .. e)
        end
        if ctx.failed > #ctx.examples then
          print(('    ... and %d more'):format(ctx.failed - #ctx.examples))
        end
      end
    end
  end

  print(('\n%d tests, %d assertions, %d failures  (%.2fs)'):format(
    H.tests, H.assertions, H.failures, os.clock() - t0))
  return H.failures == 0
end

return H
