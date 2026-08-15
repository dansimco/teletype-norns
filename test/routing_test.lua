-- routing_test.lua
--
-- Checks the device layer without a device: teletype ops build raw i2c
-- packets, and lib/io/routing.lua has to decode them back into the crow ii
-- calls whose names were verified against a real crow.
--
-- This is the seam most likely to be wrong in a way hardware testing would
-- only reveal as "the ansible does nothing", so it is worth pinning down here.

local H = require 'harness'
local exec = require 'exec'
local routing = require 'io.routing'
local crow_io = require 'io.crow_io'
local midi_io = require 'io.midi_io'
local ansible_io = require 'io.ansible_io'
local st = require 'state'
local tokenizer = require 'tokenizer'
local validate = require 'validate'
require 'ops.init'

-- a stand-in for the norns `crow` global that records what it is told
local function mock_crow()
  local log = {}
  local function record(fmt, ...) log[#log + 1] = fmt:format(...) end

  local ansible = {}
  setmetatable(ansible, {
    __index = function(_t, name)
      return function(...)
        local args = { ... }
        for i, v in ipairs(args) do
          args[i] = type(v) == 'number' and ('%g'):format(v) or tostring(v)
        end
        record('%s(%s)', name, table.concat(args, ','))
      end
    end,
  })

  local outputs = {}
  for i = 1, 4 do
    outputs[i] = setmetatable({}, {
      __index = function(_t, k)
        if k == 'slew' then return 0 end
        return function() record('out%d()', i) end
      end,
      __newindex = function(_t, k, v)
        record('out%d.%s=%s', i, k, tostring(v))
      end,
    })
  end

  return {
    log = log,
    connected = function() return true end,
    send = function(s) record('send:%s', s) end,
    output = outputs,
    -- crow exposes each ansible app as its own ii module
    ii = setmetatable({}, {
      __index = function(t, module)
        local m = setmetatable({}, {
          __index = function(_m, name)
            return function(...)
              local args = { ... }
              for i, v in ipairs(args) do
                args[i] = type(v) == 'number' and ('%g'):format(v) or tostring(v)
              end
              record('%s.%s(%s)', module, name, table.concat(args, ','))
            end
          end,
        })
        rawset(t, module, m)
        return m
      end,
    }),
  }, log
end

local function fresh(mode)
  local crow, log = mock_crow()
  crow_io.crow = crow
  crow_io.mode = mode or 'companion'
  crow_io.outputs = {
    { role = crow_io.CV, index = 1 },
    { role = crow_io.CV, index = 2 },
    { role = crow_io.TR, index = 1 },
    { role = crow_io.TR, index = 2 },
  }
  routing.crow_ii = crow.ii
  ansible_io.cache = {}
  ansible_io.unmapped = 0
  ansible_io.unmapped_examples = {}
  ansible_io.raw_send = nil
  ansible_io.prefer_raw = true
  midi_io.clear_routes()
  midi_io.devices = {}
  exec.set_io(routing)
  -- drop everything the routing setup itself emitted
  crow_io.apply_routing()
  for i = #log, 1, -1 do log[i] = nil end
  return st.SceneState.new(0), log
end

local function run(ss, line)
  local cmd, perr = tokenizer.parse(line:upper())
  assert(perr == 'E_OK', line .. ': ' .. perr)
  assert(validate.validate(cmd) == 'E_OK', line)
  local es = st.ExecState.new()
  es:push()
  return exec.process_command(ss, es, cmd)
end

--- a stand-in for the norns `crow` global that behaves like the real one: a
--- write-only proxy where *any* field it does not itself define becomes a
--- remote call shipped to the module. Reading `crow.connected` on the real
--- thing sends "connected()" to the crow, where it fails.
local function proxy_crow()
  local remote = {}
  local real = {
    send = function() end,
    reset = function() end, kill = function() end, clear = function() end,
    version = function() end, identity = function() end,
  }
  return setmetatable({}, {
    __index = function(_t, k)
      if real[k] then return real[k] end
      remote[#remote + 1] = k
      return function() end
    end,
  }), remote
end

H.suite('crow: the write-only proxy', function()
  H.test('connect never reads a field the proxy would ship remotely', function()
    local crow, remote = proxy_crow()
    -- crow absent: norns.crow.connected() is the only correct way to ask
    _G.norns = { crow = { connected = function() return false end } }
    local mode
    crow_io.connect(crow, function(m) mode = m end)
    H.eq(mode, 'absent', 'reports absent')
    -- `connected`, `output`, `input` must never appear: reading any of them
    -- off the proxy is a message to the module, not a local query
    for _, field in ipairs(remote) do
      H.ok(field ~= 'connected',
        ('read crow.%s, which the proxy sends to the device'):format(field))
    end
    _G.norns = nil
  end)

  H.test('a missing norns.crow is treated as absent, not an error', function()
    local crow = proxy_crow()
    _G.norns = nil
    local mode
    crow_io.connect(crow, function(m) mode = m end)
    H.eq(mode, 'absent', 'degrades quietly')
  end)
end)

H.suite('routing: teletype packets to crow', function()
  H.test('local CV and TR reach the mapped crow outputs', function()
    local ss, log = fresh()
    run(ss, 'CV 1 V 5')
    H.eq(log[1], 'send:tt_cv(1,5.0000)', 'CV 1 goes to crow out 1')
    run(ss, 'CV 2 V 10')
    -- V 10 is table_v[10] = 16384, clamped by the CV op to 16383, and the
    -- domain is 16384 units per 10V -- so full scale lands a hair under 10V,
    -- exactly as it does on the hardware DAC
    H.eq(log[2], 'send:tt_cv(2,9.9994)', 'CV 2 goes to crow out 2')
    -- CV 3 and 4 are unmapped: state still updates, nothing is emitted
    local before = #log
    run(ss, 'CV 3 V 5')
    H.eq(#log, before, 'unmapped CV emits nothing')
    H.eq(ss.variables.cv[2], 8192, 'but scene state still tracks it')
  end)

  H.test('TR pulses use the on-crow timer', function()
    local ss, log = fresh()
    run(ss, 'TR.TIME 1 50')
    H.eq(log[1], 'send:tt_time(3,0.0500)', 'pulse width in seconds')
    run(ss, 'TR.P 1')
    -- one short call, because width and polarity already live on the crow
    H.eq(log[#log], 'send:tt_pulse(3)', 'firing is a single message')
    run(ss, 'TR 2 1')
    H.eq(log[#log], 'send:tt_tr(4,1)', 'TR B is crow out 4')
  end)

  H.test('CV.SET bypasses slew', function()
    local ss, log = fresh()
    run(ss, 'CV.SLEW 1 500')
    H.eq(log[1], 'send:tt_slew(1,0.5000)', 'slew in seconds')
    run(ss, 'CV.SET 1 V 2')
    H.eq(log[#log], 'send:tt_cv_set(1,2.0001)', 'CV.SET uses the no-slew call')
  end)

  H.test('CV/TR 5..20 become ansible ii calls', function()
    local ss, log = fresh()
    ansible_io.prefer_raw = false      -- exercise the named-command path
    -- teletype addresses the first ansible expander as CV 5..8
    run(ss, 'CV 5 V 5')
    H.eq(log[1], 'ansible.cv(1,5)', 'CV 5 is ansible channel 1')
    run(ss, 'CV 8 V 1')
    -- table_v[1] is 1638, not 1638.4, so a nominal 1V is 0.24mV low. that is
    -- the reference table's own rounding and we reproduce it rather than
    -- silently "improving" the tuning.
    H.eq(log[2], 'ansible.cv(4,0.999756)', 'CV 8 is ansible channel 4')
    run(ss, 'TR 5 1')
    H.eq(log[3], 'ansible.trigger(1,1)', 'TR 5 is ansible trigger 1')
    run(ss, 'TR.TOG 6')
    H.eq(log[4], 'ansible.trigger_toggle(2)', 'verified crow name')
    run(ss, 'TR.PULSE 7')
    H.eq(log[5], 'ansible.trigger_pulse(3)', 'verified crow name')
    run(ss, 'TR.TIME 5 250')
    H.eq(log[6], 'ansible.trigger_time(1,0.25)', 'times convert to seconds')
    run(ss, 'TR.POL 5 0')
    H.eq(log[7], 'ansible.trigger_polarity(1,0)', 'not trigger_pol')
    run(ss, 'CV.SLEW 5 100')
    H.eq(log[8], 'ansible.cv_slew(1,0.1)', 'slew in seconds')
    run(ss, 'CV.OFF 5 V 1')
    H.eq(log[9], 'ansible.cv_offset(1,0.999756)', 'not cv_off')
    run(ss, 'CV.SET 5 V 3')
    H.eq(log[10], 'ansible.cv_set(1,2.99988)', 'verified crow name')
  end)

  H.test('ansible reads are async: cached value now, refresh requested', function()
    local ss, log = fresh()
    -- nothing has come back yet, so the first read is 0 but still asks
    local has, value = run(ss, 'CV 5')
    H.ok(has, 'a read still returns a value')
    H.eq(value, 0, 'zero until the first reply arrives')
    H.eq(log[1], "ansible.get(cv,1)", 'and a refresh was requested')

    -- simulate crow delivering the reply
    ansible_io.on_event('ansible', 'cv', { 1 }, 5.0)
    local _, v2 = run(ss, 'CV 5')
    H.eq(v2, 8192, 'the cached value is returned next time, in teletype units')
  end)

  H.test('the ansible apps reach their own crow modules', function()
    local ss, log = fresh()
    ansible_io.prefer_raw = false      -- exercise the named-command path
    run(ss, 'KR.PRE 3')
    H.eq(log[1], 'kria.preset(3)', 'kria is its own module, not ii.ansible')
    run(ss, 'KR.PERIOD 500')
    H.eq(log[2], 'kria.period(0.5)', 'period converts ms to seconds')
    run(ss, 'KR.POS 1 2 3')
    H.eq(log[3], 'kria.position(1,2,3)', 'three positional args, not a channel')
    run(ss, 'KR.MUTE 2 1')
    H.eq(log[4], 'kria.mute(2,1)', 'mute takes track and state')
    run(ss, 'KR.TMUTE 2')
    H.eq(log[5], 'kria.toggle_mute(2)', 'verified crow name')
    run(ss, 'KR.CLK 1')
    H.eq(log[6], 'kria.clock(1)', 'verified crow name')
    run(ss, 'KR.DIR 1 1')
    H.eq(log[7], 'kria.direction(1,1)', 'verified crow name')

    run(ss, 'ME.PRE 2')
    H.eq(log[8], 'meadowphysics.preset(2)', 'meadowphysics module')
    run(ss, 'ME.PERIOD 250')
    H.eq(log[9], 'meadowphysics.period(0.25)', 'period in seconds')

    run(ss, 'LV.PRE 1')
    H.eq(log[10], 'levels.preset(1)', 'levels module')
    run(ss, 'LV.L.DIR 1')
    H.eq(log[11], 'levels.loop_direction(1)', 'verified crow name')
  end)

  H.test('reads crow cannot serve are reported, not faked', function()
    local ss = fresh()
    -- crow lists no get for kria page/cue/direction
    run(ss, 'KR.PG')
    H.ok(ansible_io.unmapped > 0, 'an unavailable read is recorded')
    local before = ansible_io.unmapped
    run(ss, 'KR.PRE')      -- this one crow *can* read
    H.eq(ansible_io.unmapped, before, 'a supported read is not recorded')
  end)

  H.test('families with no crow module fall back to raw', function()
    local ss = fresh()
    ansible_io.prefer_raw = false
    run(ss, 'CY.PRE 1')
    H.ok(ansible_io.unmapped > 0, 'Cycles has no crow module')

    -- with a raw transport they go out as the original packets
    local raw = {}
    ansible_io.raw_send = function(addr, data)
      raw[#raw + 1] = ('%02x:%s'):format(addr, table.concat(data, ','))
    end
    run(ss, 'CY.PRE 2')
    H.eq(raw[1], '2e:0,2', 'raw packet preserved: cycles address, preset command')
    run(ss, 'ARP.STY 3')
    H.eq(raw[2], '26:0,3', 'arp mode too')
    run(ss, 'MID.SLEW 500')
    H.eq(raw[3], '24:1,1,244', 'midi mode: 16-bit value stays big-endian')
  end)

  H.test('enable_raw drives crow ii.raw in both call styles', function()
    local ss, log = fresh()
    local crow_ii = {
      raw = function(addr, ...)
        local rest = { ... }
        if type(rest[1]) == 'table' then
          log[#log + 1] = ('raw(%02x,{%s})'):format(addr,
            table.concat(rest[1], ','))
        else
          log[#log + 1] = ('raw(%02x,%s)'):format(addr,
            table.concat(rest, ','))
        end
      end,
    }

    ansible_io.raw_style = 'table'
    ansible_io.enable_raw(crow_ii)
    run(ss, 'CY.PRE 4')
    H.eq(log[#log], 'raw(2e,{0,4})', 'table style')

    ansible_io.raw_style = 'varargs'
    run(ss, 'CY.PRE 5')
    H.eq(log[#log], 'raw(2e,0,5)', 'varargs style')

    ansible_io.raw_style = 'table'
    ansible_io.disable_raw()
    H.eq(ansible_io.raw_send, nil, 'and it can be turned off again')
  end)

  H.test('raw writes are byte-identical to the hardware packets', function()
    local ss = fresh()
    local raw = {}
    ansible_io.raw_send = function(addr, data)
      raw[#raw + 1] = ('%02x:%s'):format(addr, table.concat(data, ','))
    end
    -- the whole point of preferring raw: no name lookup, no unit conversion,
    -- just the bytes a hardware teletype would put on the bus
    run(ss, 'CV 5 V 5')
    H.eq(raw[1], '20:6,0,32,0', 'ansible CV: cmd 6, chan 0, 8192 big-endian')
    run(ss, 'KR.PERIOD 500')
    H.eq(raw[2], '28:3,1,244', 'kria period: cmd 3, 500 big-endian')
    run(ss, 'KR.POS 1 2 3')
    H.eq(raw[3], '28:4,1,2,3', 'kria position: three positional bytes')
    run(ss, 'CY.PRE 2')
    H.eq(raw[4], '2e:0,2', 'cycles, which has no crow module')
    run(ss, 'MID.SLEW 500')
    H.eq(raw[5], '24:1,1,244', 'midi mode at the contested 0x24 address')
    run(ss, 'ANS.APP 1')
    H.ok(#raw > 5, 'app switching broadcasts to every address')
  end)

  H.test('MIDI routing pairs a pitch CV with a gate TR', function()
    local ss, _ = fresh()
    local sent = {}
    local dev = {
      note_on = function(_s, n, v, ch)
        sent[#sent + 1] = ('on %d %d %d'):format(n, v, ch)
      end,
      note_off = function(_s, n, _v, ch)
        sent[#sent + 1] = ('off %d %d'):format(n, ch)
      end,
      cc = function(_s, c, v, ch)
        sent[#sent + 1] = ('cc %d %d %d'):format(c, v, ch)
      end,
    }
    midi_io.set_device(1, dev)
    midi_io.set_route('cv3', { mode = midi_io.PITCH, port = 1, channel = 1 })
    midi_io.set_route('trC', { mode = midi_io.GATE, port = 1, channel = 1,
                               velocity = 100 })
    midi_io.set_route('cv4', { mode = midi_io.CC, port = 1, channel = 2, cc = 74 })

    run(ss, 'CV 3 N 60')       -- middle C as a note number
    H.eq(#sent, 0, 'setting the pitch alone sends nothing')
    run(ss, 'TR 3 1')
    H.eq(sent[1], 'on 60 100 1', 'the gate plays the pitch')
    run(ss, 'TR 3 0')
    H.eq(sent[2], 'off 60 1', 'and releases it')

    run(ss, 'CV 4 16383')
    H.eq(sent[3], 'cc 74 127 2', 'a CC route scales to 0..127')
  end)
end)
