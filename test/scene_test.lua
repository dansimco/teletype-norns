-- scene_test.lua
--
-- Round-trips every reference preset through both the C serializer and the
-- lua one and compares the output byte for byte. That covers parsing (the
-- scripts have to compile to the same commands), pattern data, the grid block
-- we pass through untouched, and the exact whitespace of the output.

local H = require 'harness'
local scene = require 'scene'
local st = require 'state'
require 'ops.init'

local PRESETS = '../teletype/presets'
local GOLDEN = 'test/fixtures/scenes'

H.suite('scene .txt format: lua vs teletype C oracle', function()
  -- the fixture generator writes one golden file per preset
  local names = {}
  local p = io.popen('ls ' .. GOLDEN .. ' 2>/dev/null')
  if p then
    for line in p:lines() do
      if line:match('%.txt$') then names[#names + 1] = line end
    end
    p:close()
  end

  H.test('golden scenes are present', function()
    -- teletype ships tt00..tt08
    H.ok(#names >= 9, ('only %d golden scenes -- run `make fixtures`')
      :format(#names))
  end)

  H.test('round-trip matches the C byte for byte', function()
    for _, name in ipairs(names) do
      local ss = st.SceneState.new(0)
      local text, grid = scene.read_file(PRESETS .. '/' .. name, ss)
      if text then
        local got = scene.serialize(ss, text, grid)

        local f = io.open(GOLDEN .. '/' .. name, 'rb')
        local want = f:read('a')
        f:close()

        if got ~= want then
          -- report the first differing line rather than dumping both files
          local gl, wl = {}, {}
          for line in (got .. '\n'):gmatch('([^\n]*)\n') do gl[#gl + 1] = line end
          for line in (want .. '\n'):gmatch('([^\n]*)\n') do wl[#wl + 1] = line end
          local at
          for i = 1, math.max(#gl, #wl) do
            if gl[i] ~= wl[i] then at = i break end
          end
          H.eq(gl[at], wl[at],
            ('%s differs at line %s'):format(name, tostring(at)))
        else
          H.ok(true)
        end
      end
    end
  end)

  H.test('a second round-trip is stable', function()
    -- serialize(deserialize(serialize(x))) == serialize(x)
    for _, name in ipairs(names) do
      local ss1 = st.SceneState.new(0)
      local text1, grid1 = scene.read_file(PRESETS .. '/' .. name, ss1)
      if text1 then
        local once = scene.serialize(ss1, text1, grid1)
        local ss2 = st.SceneState.new(0)
        local text2, grid2 = scene.deserialize(once, ss2)
        H.eq(scene.serialize(ss2, text2, grid2), once,
          ('%s is not idempotent'):format(name))
      end
    end
  end)
end)
