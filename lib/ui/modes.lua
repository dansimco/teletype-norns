-- ui/modes.lua -- the mode shell: state, global keys, and key dispatch.
--
-- Teletype has six modes (teletype/module/globals.h). This file owns which one
-- is current and handles the keys that work everywhere; each mode file handles
-- the rest.
--
-- The one deliberate departure from hardware is the script triggers. Teletype
-- uses F1-F8, but norns intercepts F1-F5 for its own menu before a script ever
-- sees them, so scripts are on ctrl-1..8 here (ctrl-9 = M, ctrl-0 = I) with
-- F6-F10 also mapped since those do pass through. See docs/differences.md.

local exec = require 'exec'
local st = require 'state'

local M = {}

M.LIVE, M.EDIT, M.PATTERN, M.PRESET_R, M.PRESET_W, M.HELP =
  'live', 'edit', 'pattern', 'preset_r', 'preset_w', 'help'

M.mode = M.LIVE
M.last_mode = M.LIVE

--- the mode implementations, registered by ui/init.lua
M.handlers = {}

--- set by the host: the scene, and callbacks for things the shell cannot do
M.ss = nil
M.on_dirty = nil
M.on_save = nil
M.on_load = nil
M.on_clear_delays = nil
M.on_refresh = nil        -- rescan the scene slots

local function dirty() if M.on_dirty then M.on_dirty() end end

function M.set(mode)
  if mode ~= M.HELP then M.last_mode = M.mode end
  M.mode = mode
  local h = M.handlers[mode]
  if h and h.enter then h.enter() end
  dirty()
end

--- return to whichever of live/edit/pattern we came from
function M.set_last()
  if M.mode == M.last_mode then return end
  local back = M.last_mode
  if back ~= M.LIVE and back ~= M.EDIT and back ~= M.PATTERN then
    back = M.LIVE
  end
  M.set(back)
end

-- ------------------------------------------------------------- global keys

--- scripts reachable from a trigger key: 1-8, then M and I
local CTRL_SCRIPT = {
  ['1'] = 0, ['2'] = 1, ['3'] = 2, ['4'] = 3,
  ['5'] = 4, ['6'] = 5, ['7'] = 6, ['8'] = 7,
  ['9'] = st.METRO_SCRIPT, ['0'] = st.INIT_SCRIPT,
}

-- F6..F10 pass through norns untouched, so they map to scripts 6, 7, 8, M, I
local FKEY_SCRIPT = {
  F6 = 5, F7 = 6, F8 = 7, F9 = st.METRO_SCRIPT, F10 = st.INIT_SCRIPT,
}

--- handle keys that work in every mode. returns true if consumed.
-- teletype/module/main.c:853 process_global_keys
function M.global_key(key, mods)
  local plain = not mods.ctrl and not mods.alt

  -- tab: live -> edit -> pattern -> live
  if plain and not mods.shift and key == 'TAB' then
    if M.mode == M.LIVE then M.set(M.EDIT)
    elseif M.mode == M.EDIT then M.set(M.PATTERN)
    else M.set(M.LIVE) end
    return true
  end

  if key == 'ESC' then
    if mods.alt then
      M.set(M.PRESET_W)
    elseif mods.meta then
      -- win-esc on hardware: panic. clears delays, the stack and any slews.
      if M.on_clear_delays then M.on_clear_delays() end
    elseif M.mode == M.PRESET_R then
      M.set_last()
    else
      M.set(M.PRESET_R)
    end
    return true
  end

  -- alt-? or alt-h: help.
  --
  -- Note the shift: the reference binds help to shift-alt-slash (which is
  -- alt-?), leaving plain alt-slash to edit mode for commenting a line out.
  -- Claiming alt-slash here would swallow that.
  if mods.alt and ((mods.shift and key == 'SLASH') or key == 'H') then
    if M.mode == M.HELP then M.set_last() else M.set(M.HELP) end
    return true
  end

  -- ctrl-1..0 run scripts; this is the norns-specific remap
  if mods.ctrl and CTRL_SCRIPT[key] then
    exec.run_script(M.ss, CTRL_SCRIPT[key])
    dirty()
    return true
  end
  if plain and FKEY_SCRIPT[key] then
    exec.run_script(M.ss, FKEY_SCRIPT[key])
    dirty()
    return true
  end

  return false
end

-- ---------------------------------------------------------------- dispatch

--- a key press. `key` is a norns keycode, `mods` is {shift, ctrl, alt, meta}.
function M.key(key, mods)
  if M.global_key(key, mods) then return end
  local h = M.handlers[M.mode]
  if h and h.key then h.key(key, mods) end
  dirty()
end

--- a printable character
function M.char(ch)
  local h = M.handlers[M.mode]
  if h and h.char then h.char(ch) end
  dirty()
end

--- norns encoders and keys, for when no keyboard is attached
function M.enc(n, d)
  local h = M.handlers[M.mode]
  if h and h.enc then h.enc(n, d) end
  dirty()
end

function M.norns_key(n, z)
  local h = M.handlers[M.mode]
  if h and h.norns_key then h.norns_key(n, z) end
  dirty()
end

function M.redraw()
  local h = M.handlers[M.mode]
  if h and h.redraw then h.redraw() end
end

return M
