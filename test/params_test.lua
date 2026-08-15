-- params_test.lua
--
-- The params page and the clocks are the two places where a norns-side
-- decision turns into teletype behaviour, so both are written to keep their
-- logic separable from the norns globals and both are checked here.

local H = require 'harness'
local clocks = require 'clocks'
local crow_io = require 'io.crow_io'
local midi_io = require 'io.midi_io'
local params_page = require 'params_page'
local st = require 'state'

--- a stand-in for params:get()
local function reader(values)
  return function(id)
    if values[id] == nil then
      error('test asked for an unset param: ' .. id)
    end
    return values[id]
  end
end

--- the defaults the params page ships with
local function default_values()
  local v = {
    tt_crow_out_1 = 2,   -- CV 1
    tt_crow_out_2 = 3,   -- CV 2
    tt_crow_out_3 = 6,   -- TR A
    tt_crow_out_4 = 7,   -- TR B
    tt_gate_level = 5,
  }
  for _, dest in ipairs(params_page.DESTINATIONS) do
    v['tt_midi_mode_' .. dest.id] = 1     -- off
    v['tt_midi_port_' .. dest.id] = 1
    v['tt_midi_chan_' .. dest.id] = 1
    v['tt_midi_cc_' .. dest.id] = 1
    v['tt_midi_vel_' .. dest.id] = 100
  end
  return v
end

H.suite('params: routing', function()
  H.test('every output role decodes', function()
    -- 1 is off, 2..5 are CV 1..4, 6..9 are TR A..D
    H.eq(params_page.decode_role(1).role, crow_io.OFF, 'off')
    for i = 1, 4 do
      local d = params_page.decode_role(1 + i)
      H.eq(d.role, crow_io.CV, ('option %d is a CV'):format(1 + i))
      H.eq(d.index, i, ('option %d is CV %d'):format(1 + i, i))
    end
    for i = 1, 4 do
      local d = params_page.decode_role(5 + i)
      H.eq(d.role, crow_io.TR, ('option %d is a TR'):format(5 + i))
      H.eq(d.index, i, ('option %d is TR %s'):format(5 + i,
        string.char(64 + i)))
    end
  end)

  H.test('the default split is two CV and two gates', function()
    crow_io.mode = 'stock'
    crow_io.crow = nil
    params_page.apply_crow_routing(reader(default_values()))
    H.eq(crow_io.cv_out[0], 1, 'CV 1 is crow out 1')
    H.eq(crow_io.cv_out[1], 2, 'CV 2 is crow out 2')
    H.eq(crow_io.tr_out[0], 3, 'TR A is crow out 3')
    H.eq(crow_io.tr_out[1], 4, 'TR B is crow out 4')
    H.eq(crow_io.cv_out[2], nil, 'CV 3 is unpatched')
    H.eq(crow_io.tr_out[2], nil, 'TR C is unpatched')
  end)

  H.test('reassigning outputs rebuilds the lookups', function()
    crow_io.mode = 'stock'
    crow_io.crow = nil
    local v = default_values()
    -- all four as gates
    v.tt_crow_out_1, v.tt_crow_out_2 = 6, 7
    v.tt_crow_out_3, v.tt_crow_out_4 = 8, 9
    params_page.apply_crow_routing(reader(v))
    for i = 0, 3 do
      H.eq(crow_io.tr_out[i], i + 1, ('TR %s is out %d'):format(
        string.char(65 + i), i + 1))
    end
    H.eq(next(crow_io.cv_out), nil, 'no CV is patched')
  end)

  H.test('two outputs may not claim the same destination', function()
    crow_io.mode = 'stock'
    crow_io.crow = nil
    local v = default_values()
    v.tt_crow_out_1, v.tt_crow_out_2 = 2, 2   -- both CV 1
    params_page.apply_crow_routing(reader(v))
    -- the later output wins; the important thing is that it resolves to one
    -- output rather than leaving a stale entry
    H.eq(crow_io.cv_out[0], 2, 'the last assignment wins')
  end)

  H.test('midi routes are built only for enabled destinations', function()
    local v = default_values()
    v.tt_midi_mode_cv3 = 2       -- pitch
    v.tt_midi_chan_cv3 = 5
    v.tt_midi_mode_trC = 3       -- gate
    v.tt_midi_chan_trC = 5
    v.tt_midi_vel_trC = 64
    v.tt_midi_mode_cv4 = 4       -- cc
    v.tt_midi_cc_cv4 = 74
    params_page.apply_midi_routing(reader(v))

    H.eq(midi_io.routes.cv3.mode, midi_io.PITCH, 'CV 3 sends pitch')
    H.eq(midi_io.routes.cv3.channel, 5, 'on channel 5')
    H.eq(midi_io.routes.trC.mode, midi_io.GATE, 'TR C gates it')
    H.eq(midi_io.routes.trC.velocity, 64, 'with its own velocity')
    H.eq(midi_io.routes.cv4.cc, 74, 'CV 4 sends CC 74')
    H.eq(midi_io.routes.cv1, nil, 'destinations left off have no route')
  end)
end)

-- a stand-in for norns' metro library
local function mock_metro()
  local made = {}
  return {
    made = made,
    init = function(fn, time, count)
      local m = { fn = fn, time = time, count = count, running = false }
      function m:start() self.running = true end
      function m:stop() self.running = false end
      made[#made + 1] = m
      return m
    end,
  }
end

H.suite('clocks', function()
  H.test('three timers start, and the metro waits for the scene', function()
    local metro = mock_metro()
    local ss = st.SceneState.new(0)
    local io_impl = { ticks = 0 }
    clocks.start(metro, ss, io_impl)

    H.eq(#metro.made, 3, 'tick, metro and midi')
    H.eq(metro.made[1].time, 0.01, 'the tick runs at 10ms, like RATE_CLOCK')
    H.ok(metro.made[1].running, 'the tick starts immediately')
    H.eq(metro.made[3].time, 0.025, 'midi polls at 25ms')
    -- M defaults to 1000ms with M.ACT on, so the metro is armed
    H.ok(metro.made[2].running, 'the metro is armed from the scene')
    H.eq(metro.made[2].time, 1, 'at M = 1000ms')
    clocks.stop()
  end)

  H.test('the metro retimes when M changes', function()
    local metro = mock_metro()
    local ss = st.SceneState.new(0)
    clocks.start(metro, ss, { ticks = 0 })

    ss.variables.m = 250
    clocks.update_metro()
    H.eq(metro.made[2].time, 0.25, 'M 250 is a quarter second')

    ss.variables.m_act = 0
    clocks.update_metro()
    H.ok(not metro.made[2].running, 'M.ACT 0 stops it')

    ss.variables.m_act = 1
    clocks.update_metro()
    H.ok(metro.made[2].running, 'and M.ACT 1 starts it again')
    clocks.stop()
  end)

  H.test('a scene cannot ask for a zero-length metro', function()
    local metro = mock_metro()
    local ss = st.SceneState.new(0)
    clocks.start(metro, ss, { ticks = 0 })
    -- M is clamped by the op, but a scene file is loaded straight into state
    ss.variables.m = 0
    clocks.update_metro()
    H.eq(metro.made[2].time, st.METRO_MIN_UNSUPPORTED_MS / 1000,
      'clamped to the M! floor rather than spinning')
    clocks.stop()
  end)

  H.test('the tick advances the io clock in step', function()
    local metro = mock_metro()
    local ss = st.SceneState.new(0)
    local io_impl = { ticks = 0 }
    clocks.start(metro, ss, io_impl)

    -- TIME and LAST read this clock, so it has to move with the delay queue
    metro.made[1].fn()
    H.eq(io_impl.ticks, 10, 'one tick is 10ms')
    metro.made[1].fn()
    metro.made[1].fn()
    H.eq(io_impl.ticks, 30, 'and it accumulates')
    clocks.stop()
  end)

  H.test('the metro script only runs while M.ACT is on', function()
    local metro = mock_metro()
    local ss = st.SceneState.new(0)
    clocks.start(metro, ss, { ticks = 0 })

    local fired = 0
    clocks.on_metro_fire = function() fired = fired + 1 end
    metro.made[2].fn()
    H.eq(fired, 1, 'fires with M.ACT on')

    ss.variables.m_act = 0
    metro.made[2].fn()
    H.eq(fired, 1, 'and not with it off')
    clocks.on_metro_fire = nil
    clocks.stop()
  end)
end)
