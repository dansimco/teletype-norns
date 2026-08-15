-- params_page.lua -- the norns params that drive output routing.
--
-- Teletype has four CV and four TR jacks; crow has four outputs total. So the
-- eight destinations are assigned to crow outputs individually, and any of
-- them can additionally be sent to MIDI. A destination assigned to neither
-- still exists in scene state and still works -- CV 3 can drive a MIDI note
-- while nothing is patched.
--
-- The translation from param values to routing tables lives in `apply_*`
-- functions that take a plain reader function, so the mapping can be tested
-- without norns.

local crow_io = require 'io.crow_io'
local draw = require 'ui.draw'
local midi_io = require 'io.midi_io'
local ansible_io = require 'io.ansible_io'

local M = {}

--- what a crow output can be. index into this list is the param value.
M.OUTPUT_ROLES = {
  'off',
  'CV 1', 'CV 2', 'CV 3', 'CV 4',
  'TR A', 'TR B', 'TR C', 'TR D',
}

--- the eight teletype destinations, in param order
M.DESTINATIONS = {
  { id = 'cv1', name = 'CV 1', kind = 'cv', index = 1 },
  { id = 'cv2', name = 'CV 2', kind = 'cv', index = 2 },
  { id = 'cv3', name = 'CV 3', kind = 'cv', index = 3 },
  { id = 'cv4', name = 'CV 4', kind = 'cv', index = 4 },
  { id = 'trA', name = 'TR A', kind = 'tr', index = 1 },
  { id = 'trB', name = 'TR B', kind = 'tr', index = 2 },
  { id = 'trC', name = 'TR C', kind = 'tr', index = 3 },
  { id = 'trD', name = 'TR D', kind = 'tr', index = 4 },
}

M.MIDI_MODES = { 'off', 'pitch', 'gate', 'cc' }

--- decode an OUTPUT_ROLES index into a crow_io output entry
function M.decode_role(value)
  local label = M.OUTPUT_ROLES[value]
  if not label or label == 'off' then
    return { role = crow_io.OFF, index = 0 }
  end
  local kind, n = label:match('^(%a+)%s+(%S)$')
  if kind == 'CV' then
    return { role = crow_io.CV, index = tonumber(n) }
  end
  -- TR A..D
  return { role = crow_io.TR, index = string.byte(n) - string.byte('A') + 1 }
end

--- push the four crow-output params into crow_io.
-- `get` is a function(param_id) -> value, so this is testable with a table.
function M.apply_crow_routing(get)
  for out = 1, 4 do
    crow_io.outputs[out] = M.decode_role(get('tt_crow_out_' .. out))
  end
  crow_io.gate_level = get('tt_gate_level')
  crow_io.apply_routing()
end

--- push the MIDI destination params into midi_io
function M.apply_midi_routing(get)
  midi_io.clear_routes()
  for _, dest in ipairs(M.DESTINATIONS) do
    local mode = M.MIDI_MODES[get('tt_midi_mode_' .. dest.id)]
    if mode and mode ~= 'off' then
      midi_io.set_route(dest.id, {
        mode = mode,
        port = get('tt_midi_port_' .. dest.id),
        channel = get('tt_midi_chan_' .. dest.id),
        cc = get('tt_midi_cc_' .. dest.id),
        velocity = get('tt_midi_vel_' .. dest.id),
      })
    end
  end
end

-- --------------------------------------------------------------- norns wiring

--- build the params page. `on_change` is called whenever routing changes.
function M.add(on_change)
  local function get(id) return params:get(id) end
  local function changed() if on_change then on_change() end end

  params:add_separator('tt_sep_crow', 'teletype: crow')

  params:add_group('tt_crow', 'crow outputs', 6)
  -- default: two CV, two gates -- the most useful split for a first patch
  local defaults = { 2, 3, 6, 7 }   -- CV 1, CV 2, TR A, TR B
  for out = 1, 4 do
    params:add_option('tt_crow_out_' .. out, 'out ' .. out,
      M.OUTPUT_ROLES, defaults[out])
    params:set_action('tt_crow_out_' .. out, function()
      M.apply_crow_routing(get)
      changed()
    end)
  end
  params:add_control('tt_gate_level', 'gate level',
    controlspec.new(1, 10, 'lin', 0.1, 5, 'V'))
  params:set_action('tt_gate_level', function()
    M.apply_crow_routing(get)
  end)
  params:add_option('tt_crow_timing', 'timing',
    { 'on crow', 'from norns' }, 1)
  params:set_action('tt_crow_timing', function(v)
    -- 'on crow' uses the uploaded companion script; 'from norns' falls back to
    -- the stock crow API, which is slower but touches nothing on the device
    crow_io.mode = (v == 1) and 'companion' or 'stock'
    M.apply_crow_routing(get)
  end)

  params:add_separator('tt_sep_ui', 'teletype: display')
  params:add_group('tt_ui', 'display', 3)
  -- 68 (Particle) at size 8: 32 columns and 8 rows, assuming the 4px cell in
  -- ui/draw. 25 (bmp/tom-thumb) at size 6 is the other 4px-wide fit, 10 rows.
  -- Anything else will need draw.CW adjusting to match.
  params:add_number('tt_font_face', 'font', 1, 69, 68)
  params:add_number('tt_font_size', 'size', 4, 16, 8)
  params:add_option('tt_font_case', 'case', { 'upper', 'as typed' }, 1)
  for _, id in ipairs({ 'tt_font_face', 'tt_font_size', 'tt_font_case' }) do
    params:set_action(id, function()
      draw.configure(params:get('tt_font_face'), params:get('tt_font_size'),
        params:get('tt_font_case') == 1)
      changed()
    end)
  end

  params:add_separator('tt_sep_i2c', 'teletype: i2c')
  params:add_group('tt_i2c', 'ansible over i2c', 2)
  params:add_option('tt_ii_writes', 'writes', { 'raw bytes', 'named' }, 1)
  params:set_action('tt_ii_writes', function(v)
    ansible_io.prefer_raw = (v == 1)
  end)
  params:add_option('tt_ii_raw_style', 'raw call style',
    { 'table', 'varargs' }, 1)
  params:set_action('tt_ii_raw_style', function(v)
    ansible_io.raw_style = (v == 1) and 'table' or 'varargs'
  end)

  params:add_separator('tt_sep_midi', 'teletype: midi out')
  for _, dest in ipairs(M.DESTINATIONS) do
    params:add_group('tt_midi_' .. dest.id, dest.name .. ' to midi', 5)
    params:add_option('tt_midi_mode_' .. dest.id, 'mode', M.MIDI_MODES, 1)
    params:add_number('tt_midi_port_' .. dest.id, 'device', 1, 16, 1)
    params:add_number('tt_midi_chan_' .. dest.id, 'channel', 1, 16, 1)
    params:add_number('tt_midi_cc_' .. dest.id, 'cc number', 0, 127, 1)
    params:add_number('tt_midi_vel_' .. dest.id, 'velocity', 1, 127, 100)
    for _, suffix in ipairs({ 'mode', 'port', 'chan', 'cc', 'vel' }) do
      params:set_action('tt_midi_' .. suffix .. '_' .. dest.id, function()
        M.apply_midi_routing(get)
      end)
    end
  end
end

--- apply everything once at startup, after params have been read
function M.apply_all()
  local function get(id) return params:get(id) end
  M.apply_crow_routing(get)
  M.apply_midi_routing(get)
end

return M
