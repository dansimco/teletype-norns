-- ui/init.lua -- assemble the UI and connect it to norns' input.
--
-- The keyboard is the primary interface, as on the hardware. norns' encoders
-- and keys are a fallback so the script is usable without one -- every mode
-- implements enc/norns_key, but they are a reduced view of what the keyboard
-- can do.

local activity = require 'ui.activity'
local draw = require 'ui.draw'
local modes = require 'ui.modes'

local M = {}

M.modes = modes
M.activity = activity
M.live = require 'ui.live'
M.edit = require 'ui.edit'
M.pattern = require 'ui.pattern'
M.preset = require 'ui.preset'
M.help = require 'ui.help'

modes.handlers[modes.LIVE] = M.live
modes.handlers[modes.EDIT] = M.edit
modes.handlers[modes.PATTERN] = M.pattern
modes.handlers[modes.PRESET_R] = M.preset.read
modes.handlers[modes.PRESET_W] = M.preset.write
modes.handlers[modes.HELP] = M.help

-- ------------------------------------------------------------------ keyboard

--- read the modifier state.
--
-- NOTE: norns updates keyboard.state *after* calling keyboard.code, so for a
-- modifier key's own press the state still reads the previous value. That is
-- fine here -- we only ask about modifiers while handling a non-modifier key,
-- by which point they are current.
local function mods()
  return {
    shift = keyboard.shift() and true or false,
    ctrl = keyboard.ctrl() and true or false,
    alt = keyboard.alt() and true or false,
    meta = keyboard.meta() and true or false,
  }
end

local MODIFIERS = {
  LEFTSHIFT = true, RIGHTSHIFT = true, LEFTCTRL = true, RIGHTCTRL = true,
  LEFTALT = true, RIGHTALT = true, LEFTMETA = true, RIGHTMETA = true,
  CAPSLOCK = true,
}

--- when true, every key event is printed with its modifiers and the mode that
--- received it. Enabled from maiden with tt_keys(true).
M.echo = false

--- our installed handler, kept so a diagnostic can prove it is still the one
--- norns will call
M.installed_code = nil

--- install our keyboard handlers
function M.attach_keyboard()
  keyboard.code = function(key, value)
    -- 0 is release, 1 press, 2 repeat. we act on press and repeat, so held
    -- arrows and backspace behave as expected.
    if value == 0 then return end
    if MODIFIERS[key] then return end
    local m = mods()
    if M.echo then
      print(('key %-10s shift=%s ctrl=%s alt=%s meta=%s  mode=%s')
        :format(key, tostring(m.shift), tostring(m.ctrl), tostring(m.alt),
          tostring(m.meta), modes.mode))
    end
    modes.key(key, m)
  end

  keyboard.char = function(ch)
    -- a character that arrives with ctrl or alt held was already handled as a
    -- keycode; letting it through as well would type the letter too
    local m = mods()
    if m.ctrl or m.alt then return end
    modes.char(ch)
  end

  M.installed_code = keyboard.code
end

--- why keyboard input might not be arriving.
-- norns routes key events through several gates before a script sees them, and
-- when one of them swallows input there is no error -- it simply goes quiet.
function M.keyboard_report()
  local lines = {}
  local function say(...) lines[#lines + 1] = string.format(...) end

  say('handler installed: %s',
    tostring(M.installed_code ~= nil and keyboard.code == M.installed_code))
  say('echo: %s', tostring(M.echo))

  -- keyboard.process checks these first, in this order
  local ok, te = pcall(require, 'lib/textentry_kbd')
  if ok and te and te.code then
    say('BLOCKED: textentry has the keyboard')
  end
  if _menu and _menu.mode then
    say('BLOCKED: the norns menu has the keyboard (K1 or F5 toggles it)')
  end

  -- is a keyboard even attached?
  local found = false
  if hid and hid.devices then
    for _, dev in pairs(hid.devices) do
      local kind = dev.is_ascii_keyboard and 'keyboard' or 'other'
      say('hid: %s (%s)', tostring(dev.name), kind)
      if dev.is_ascii_keyboard then found = true end
    end
  end
  if not found then
    say('no ascii keyboard detected -- the UI you are driving is E1/E2/E3')
  end
  return table.concat(lines, '\n')
end

function M.detach_keyboard()
  if keyboard and keyboard.clear then keyboard.clear() end
end

-- ------------------------------------------------------------------- norns

function M.enc(n, d)
  -- E1 cycles the three main modes everywhere, so there is always a way out
  if n == 1 then
    if d > 0 then
      if modes.mode == modes.LIVE then modes.set(modes.EDIT)
      elseif modes.mode == modes.EDIT then modes.set(modes.PATTERN)
      else modes.set(modes.LIVE) end
    else
      if modes.mode == modes.PATTERN then modes.set(modes.EDIT)
      elseif modes.mode == modes.EDIT then modes.set(modes.LIVE)
      else modes.set(modes.PATTERN) end
    end
    return
  end
  modes.enc(n, d)
end

function M.key(n, z) modes.norns_key(n, z) end

-- ------------------------------------------------------------------- draw

--- the mode indicator, drawn over every mode
local LABEL = {
  live = 'live', edit = 'edit', pattern = 'patt',
  preset_r = 'load', preset_w = 'save', help = 'help',
}

-- live mode's activity strip owns x 85..127 of the top row, as on the
-- hardware. Anything else drawn there has to stop short of it.
local STRIP_X = activity.BAND_X - 2

function M.redraw(status)
  draw.begin()
  modes.redraw()

  if modes.mode == modes.LIVE then
    -- no mode label here: the hardware shows none, and the icons want the
    -- room. Only the host's status -- which crow path is live, or an i2c
    -- destination we cannot reach -- and only when there is something to say.
    if status and status ~= '' then
      draw.text_right(0, status, draw.DIM, STRIP_X)
    end
  elseif modes.mode == modes.EDIT then
    draw.text_right(0, ('%s %s'):format(status or '', LABEL[modes.mode]),
      draw.DIM)
  end

  draw.finish()
end

--- point the UI at a scene.
--
-- Every mode is reset: a cursor, a half-typed pattern value or an undo
-- snapshot from the previous scene is meaningless against a new one, and the
-- undo in particular would restore lines into the wrong place.
function M.set_scene(ss, text)
  modes.ss = ss
  modes.scene_text = text
  for _, handler in pairs(modes.handlers) do
    if handler.reset then handler.reset() end
  end
end

return M
