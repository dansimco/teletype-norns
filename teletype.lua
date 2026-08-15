-- teletype
-- a monome teletype for norns
--
-- outputs via crow, ansible
-- over crow's i2c, and midi.
--
-- E1 mode  E2/E3 select
-- K2 run   K3 comment
--
-- a USB keyboard gives the
-- full teletype interface.
--
-- llll  ctrl+1..8 run scripts
-- llll  ctrl+9 M  ctrl+0 I

-- norns does not put a script's own folder on package.path, so the modules
-- below -- and the requires *they* make of each other -- would not resolve.
-- Prepending lib/ once here means every module can use plain `require`, and
-- the exact same paths work under the headless test runner.
local LIB = norns.state.path .. 'lib/?.lua;'
if not package.path:find(LIB, 1, true) then
  package.path = LIB .. package.path
end

-- norns keeps package.loaded across script loads, and every module here is a
-- stateful singleton -- the op registry, the routing tables, the read cache.
-- Without this, reloading the script would inherit the previous run's state
-- and, worse, re-register ops onto an already-populated table. Drop ours (and
-- only ours: `io` alone is the Lua standard library).
for name in pairs(package.loaded) do
  if name:match('^ops%.') or name:match('^io%.') or name:match('^ui%.') or ({
    clocks = true, exec = true, params_page = true, scene = true,
    state = true, tokenizer = true, validate = true, command = true,
    helpers = true, int16 = true, random = true, tables = true,
    scale = true, chaos = true, turtle = true, version = true,
  })[name] then
    package.loaded[name] = nil
  end
end

local clocks = require 'clocks'
local exec = require 'exec'
local params_page = require 'params_page'
local routing = require 'io.routing'
local ansible_io = require 'io.ansible_io'
local crow_io = require 'io.crow_io'
local midi_io = require 'io.midi_io'
local scene = require 'scene'
local st = require 'state'
local tokenizer = require 'tokenizer'
local ui = require 'ui.init'
local validate = require 'validate'
require 'ops.init'

-- the scene, its description text and its grid block
local ss, scene_text, scene_grid

-- what the screen is showing. the full mode set arrives with the UI work;
-- until then this is enough to see that a scene is alive.
local status = { line = '', crow = 'connecting', dirty = true }
local screen_metro

local SCENE_DIR = 'scenes/'

-- Bumped whenever this file or lib/ changes. Printed on load so it is obvious
-- at a glance whether the running instance is the current code -- "did it
-- reload?" is otherwise indistinguishable from "the fix did not work".
--
-- lib/version.lua carries the same string. If they disagree, only part of the
-- script was copied across, which otherwise presents as fixes silently not
-- taking effect.
local VERSION = 'ui-6'
local lib_version = (function()
  local ok, v = pcall(require, 'version')
  return ok and v or nil
end)()

-- ---------------------------------------------------------------- scenes

local function scene_path(slot)
  return norns.state.data .. SCENE_DIR .. ('tt%02d.txt'):format(slot)
end

--- load a scene slot. missing files are not an error -- an empty slot is a
--- blank scene, exactly as on hardware.
local function load_scene(slot)
  local fresh = st.SceneState.new(math.random(0, 32767))
  local text, grid, warnings = scene.read_file(scene_path(slot), fresh)
  if not text then
    text, grid = scene.new_text(), scene.new_grid()
  else
    for _, warn in ipairs(warnings) do print('teletype: ' .. warn) end
  end
  ss, scene_text, scene_grid = fresh, text, grid
  clocks.set_scene(ss)
  ui.set_scene(ss, scene_text)

  -- the INIT script runs once on load, with scene changes suppressed
  ss.initializing = true
  exec.run_script(ss, st.INIT_SCRIPT)
  ss.initializing = false
  status.dirty = true
end

local function save_scene(slot)
  util.make_dir(norns.state.data .. SCENE_DIR)
  local ok, err = scene.write_file(scene_path(slot), ss, scene_text, scene_grid)
  if not ok then print('teletype: ' .. tostring(err)) end
  M_refresh_slots()
  return ok
end

--- read the first description line of every slot, so the load browser can
--- show what each one is rather than 32 identical numbers
function M_refresh_slots()
  local index = {}
  for slot = 0, ui.preset.SLOTS - 1 do
    local f = io.open(scene_path(slot), 'rb')
    if f then
      -- an empty string marks "file exists but has no description", which the
      -- browser shows differently from an empty slot
      index[slot] = ''
      for line in f:lines() do
        if line:match('^#') then break end
        local trimmed = line:gsub('%s+$', '')
        if trimmed ~= '' then index[slot] = trimmed break end
      end
      f:close()
    end
  end
  ui.preset.set_index(index)
end

-- ------------------------------------------------------------------ crow

--- the coroutine uploading the companion script, so cleanup can cancel it.
-- norns.crow.loadscript sleeps between lines; if the script is unloaded
-- mid-upload the clock outlives it and norns errors resuming a dead thread.
local crow_upload = nil

local function setup_crow()
  crow_io.crow = crow
  routing.crow_ii = crow.ii
  ansible_io.enable_raw(crow.ii)
  crow_upload = crow_io.connect(crow, function(mode)
    crow_upload = nil
    status.crow = mode
    status.dirty = true
    print('teletype: crow timing = ' .. mode)
  end)
end

--- crow may be plugged in after the script starts, or reconnect after a
--- reboot -- either way its VM is empty, so the companion has to go up again.
local function watch_crow()
  norns.crow.add = function(id, name, dev)
    print('teletype: crow connected, uploading companion')
    setup_crow()
  end
  norns.crow.remove = function()
    status.crow = 'absent'
    status.dirty = true
  end
end

-- ------------------------------------------------------------------ midi

local midi_devices = {}

-- forward declaration: setup_midi installs this as the handler, and it is
-- defined below. without this the assignment would capture a nil global and
-- midi input would go quietly nowhere.
local midi_event

local function setup_midi()
  for port = 1, 16 do
    local dev = midi.connect(port)
    midi_devices[port] = dev
    midi_io.set_device(port, dev)
    dev.event = midi_event
  end
end

--- collect an incoming MIDI event into the scene's queues.
-- The bound scripts are run by the 25ms poll in lib/clocks.lua, matching the
-- way the hardware batches events between polls.
function midi_event(data)
  if not ss then return end
  local msg = midi.to_msg(data)
  local m = ss.midi
  local MAX = st.MAX_MIDI_EVENTS

  if msg.type == 'note_on' then
    m.last_event_type, m.last_note = 1, msg.note
    m.last_velocity, m.last_channel = msg.vel, (msg.ch or 1) - 1
    if m.on_count < MAX then
      m.note_on[m.on_count] = msg.note
      m.note_vel[m.on_count] = msg.vel
      m.on_channel[m.on_count] = (msg.ch or 1) - 1
      m.on_count = m.on_count + 1
    end
  elseif msg.type == 'note_off' then
    m.last_event_type, m.last_note = 2, msg.note
    m.last_channel = (msg.ch or 1) - 1
    if m.off_count < MAX then
      m.note_off[m.off_count] = msg.note
      m.off_channel[m.off_count] = (msg.ch or 1) - 1
      m.off_count = m.off_count + 1
    end
  elseif msg.type == 'cc' then
    m.last_event_type, m.last_controller = 3, msg.cc
    m.last_cc, m.last_channel = msg.val, (msg.ch or 1) - 1
    if m.cc_count < MAX then
      m.cn[m.cc_count] = msg.cc
      m.cc[m.cc_count] = msg.val
      m.cc_channel[m.cc_count] = (msg.ch or 1) - 1
      m.cc_count = m.cc_count + 1
    end
  elseif msg.type == 'start' and m.start_script >= 0 then
    exec.run_script(ss, m.start_script)
  elseif msg.type == 'stop' and m.stop_script >= 0 then
    exec.run_script(ss, m.stop_script)
  elseif msg.type == 'continue' and m.continue_script >= 0 then
    exec.run_script(ss, m.continue_script)
  end
end

-- ------------------------------------------------------------- lifecycle

function init()
  ss = st.SceneState.new(math.random(0, 32767))
  scene_text, scene_grid = scene.new_text(), scene.new_grid()

  -- the core talks only to this
  exec.set_io(routing)

  -- retime the metro whenever a scene changes M or M.ACT
  routing.on_metro_change = function(reset)
    if reset then clocks.reset_metro() else clocks.update_metro() end
  end
  routing.on_pattern_change = function() status.dirty = true end
  routing.on_vars_change = function() status.dirty = true end
  -- the delay, stack and mute indicators change with no input event
  routing.on_activity = function() status.dirty = true end

  params_page.add(function() status.dirty = true end)
  params:bang()
  params_page.apply_all()

  -- nothing to measure: the font is the module's own bitmap, so its metrics
  -- are known at load. Case is the only display setting left to apply.
  require('ui.draw').configure(params:get('tt_font_case') == 1)

  setup_crow()
  watch_crow()
  setup_midi()

  -- a device plugged in later needs both the routing entry and the handler,
  -- or it would appear connected but deliver nothing to MI.* scripts
  midi.add = function(dev)
    if dev.port then
      midi_devices[dev.port] = dev
      midi_io.set_device(dev.port, dev)
      dev.event = midi_event
    end
  end
  midi.remove = function(dev)
    if dev.port then midi_io.set_device(dev.port, nil) end
  end

  clocks.start(metro, ss, routing)
  clocks.on_metro_fire = function() status.dirty = true end
  -- a slew finishing is not an event anywhere, so watch it on the tick. gated
  -- so an idle scene is not redrawing at the tick rate; the 15fps screen metro
  -- caps it either way.
  clocks.on_tick = function()
    if routing.slewing() then status.dirty = true end
  end

  -- the UI needs a way to reach back for things only the script can do
  ui.activity.io = routing
  ui.set_scene(ss, scene_text)
  ui.modes.on_dirty = function() status.dirty = true end
  ui.modes.on_load = function(slot) load_scene(slot) end
  ui.modes.on_save = function(slot) save_scene(slot) end
  ui.modes.on_refresh = function() M_refresh_slots() end
  ui.modes.on_clear_delays = function()
    exec.clear_delays(ss)
    crow_io.reset()
  end
  ui.attach_keyboard()

  -- PRINT and the live submodes are UI concerns, so route them here
  routing.print_dashboard_value = function(i, v)
    ui.live.print(('%d: %d'):format(i + 1, v))
    status.dirty = true
  end

  M_refresh_slots()
  load_scene(0)

  -- print the REPL surface on every load, so it is obvious which helpers the
  -- *running* instance has -- adding one and forgetting to reload otherwise
  -- looks like the helper is broken
  if lib_version ~= VERSION then
    print('teletype: ####################################################')
    print(('teletype: STALE LIB. teletype.lua is %s but lib/ is %s.')
      :format(VERSION, tostring(lib_version)))
    print('teletype: copy the whole script folder -- lib/ and crow/ too,')
    print('teletype: not just teletype.lua. fixes will appear to do nothing.')
    print('teletype: ####################################################')
  end
  print(('teletype: %s loaded'):format(VERSION))
  print('teletype: tt_run("CV 1 V 5")  tt_script(9,1,"TR.P A")  tt_go(9)')
  print('teletype: tt_show(9)  tt_status()  tt_slots()  tt_load(0)  tt_save(0)')
  print('teletype: tt_keys(true) echoes keys, tt_kbd() reports keyboard status')

  -- a modest redraw rate; the UI work will drive this from activity instead
  screen_metro = metro.init(function()
    if status.dirty then redraw() end
  end, 1 / 15, -1)
  screen_metro:start()
end

function cleanup()
  ui.detach_keyboard()
  clocks.stop()
  if screen_metro then screen_metro:stop() end
  -- cancel a half-finished companion upload before the script goes away
  if crow_upload then
    clock.cancel(crow_upload)
    crow_upload = nil
  end
  midi_io.all_off()
  crow_io.reset()
end

-- ------------------------------------------------------------------- run

local SCRIPT_LABEL = { [8] = 'M', [9] = 'I' }
local function script_label(n) return SCRIPT_LABEL[n] or tostring(n + 1) end

--- compile and run one line, the way live mode does
local function run_line(text)
  local cmd, perr, pmsg = tokenizer.parse(text:upper())
  if perr ~= 'E_OK' then
    status.line = tokenizer.error_text(perr) .. (pmsg ~= '' and (': ' .. pmsg) or '')
    status.dirty = true
    return
  end
  local verr, vmsg = validate.validate(cmd)
  if verr ~= 'E_OK' then
    status.line = tokenizer.error_text(verr) .. (vmsg ~= '' and (': ' .. vmsg) or '')
    status.dirty = true
    return
  end
  local es = st.ExecState.new()
  es:push()
  local has_value, value = exec.process_command(ss, es, cmd)
  status.line = has_value and tostring(value) or ''
  status.dirty = true
end

-- Maiden helpers. The keyboard editor arrives with the UI work; until then
-- these are how a scene gets built and driven from the REPL.
--
--   tt_run("CV 1 V 5")        run one line, as live mode would
--   tt_script(9, 1, "TR.P A") put a line on a script (9 = M, 10 = I)
--   tt_go(9)                  run a whole script
--   tt_show(9)                print a script back
--   tt_load(0) / tt_save(0)   scene slots in dust/data
_G.tt_run = run_line

--- put a line on a script. `n` is 1..8, 9 for M, 10 for I; `line` is 1-based.
function _G.tt_script(n, line, text)
  local cmd, perr, pmsg = tokenizer.parse((text or ''):upper())
  if perr ~= 'E_OK' then
    print('teletype: ' .. tokenizer.error_text(perr) ..
      (pmsg ~= '' and (': ' .. pmsg) or ''))
    return
  end
  local verr, vmsg = validate.validate(cmd)
  if verr ~= 'E_OK' then
    print('teletype: ' .. tokenizer.error_text(verr) ..
      (vmsg ~= '' and (': ' .. vmsg) or ''))
    return
  end
  ss:overwrite_script_command(n - 1, line - 1, cmd)
  status.dirty = true
end

function _G.tt_go(n)
  exec.run_script(ss, n - 1)
  status.dirty = true
end

function _G.tt_show(n)
  local idx = n - 1
  print(('#%s'):format(script_label(idx)))
  if ss:script_len(idx) == 0 then print('  (empty)') end
  for l = 0, ss:script_len(idx) - 1 do
    print(('  %d: %s'):format(l + 1, tokenizer.print(ss:script_command(idx, l))))
  end
end

--- echo every key press with its modifiers, to see what the script receives
function _G.tt_version()
  print(('teletype: script %s, lib %s%s'):format(VERSION, tostring(lib_version),
    lib_version == VERSION and '' or '   <-- MISMATCH, lib/ is stale'))
end

--- report why keyboard input might not be reaching the script
function _G.tt_kbd() print(ui.keyboard_report()) end

function _G.tt_keys(on)
  ui.echo = (on ~= false)
  print('teletype: key echo ' .. (ui.echo and 'on' or 'off'))
end

--- what the scene browser can see, and what is actually on disk
function _G.tt_slots()
  M_refresh_slots()
  local dir = norns.state.data .. SCENE_DIR
  print('scene dir: ' .. dir)
  local any = false
  for slot = 0, ui.preset.SLOTS - 1 do
    local path = scene_path(slot)
    local f = io.open(path, 'rb')
    if f then
      f:close()
      any = true
      local desc = ui.preset.index[slot]
      print(('  %02d  %s'):format(slot,
        desc == nil and '(file present but not indexed!)'
        or desc == '' and '(untitled)' or desc))
    end
  end
  if not any then print('  no scene files') end
end

function _G.tt_load(slot) load_scene(slot or 0) end
function _G.tt_save(slot) save_scene(slot or 0); print('saved') end

--- what the io layer is actually doing, for when something is not moving
function _G.tt_status()
  print(('crow: %s'):format(status.crow))
  for out = 1, 4 do
    local o = crow_io.outputs[out]
    print(('  out %d: %s %s'):format(out, o.role,
      o.role == 'off' and '' or tostring(o.index)))
  end
  print(('M %d %s'):format(ss.variables.m,
    ss.variables.m_act ~= 0 and 'on' or 'off'))
  print(('delays %d  stack %d'):format(ss.delay.count, ss.stack_op.top))
  if ansible_io.unmapped > 0 then
    print(('unmapped i2c packets: %d'):format(ansible_io.unmapped))
    for _, ex in ipairs(ansible_io.unmapped_examples) do print('  ' .. ex) end
  end
end

-- ------------------------------------------------------------------ norns UI

function enc(n, d)
  ui.enc(n, d)
  status.dirty = true
end

function key(n, z)
  ui.key(n, z)
  status.dirty = true
end

function redraw()
  status.dirty = false
  -- the status strip shows what the io layer is doing: which crow path is
  -- live, and whether a scene is asking for i2c we cannot deliver
  local strip = status.crow == 'companion' and '' or status.crow
  if ansible_io.unmapped > 0 then
    strip = ('i2c?%d'):format(ansible_io.unmapped)
  end
  ui.redraw(strip)
end
