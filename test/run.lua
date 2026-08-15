-- run.lua -- test entry point.
--
--   lua5.4 test/run.lua            run everything
--   lua5.4 test/run.lua parse      run only suites whose file matches "parse"
--
-- Run from the project root; see the Makefile target `make test`.

package.path = table.concat({
  'lib/?.lua',
  'test/?.lua',
  package.path,
}, ';')

local H = require 'harness'

local TESTS = {
  'unit_test',
  'parse_test',
  'process_test',
  'scene_test',
  'routing_test',
  'params_test',
  'editor_test',
  'ui_test',
  'draw_test',
  'coverage_test',
  'reload_test',
}

local filter = ...

for _, name in ipairs(TESTS) do
  if not filter or name:find(filter, 1, true) then
    require(name)
  end
end

os.exit(H.run() and 0 or 1)
