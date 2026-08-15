-- io/ansible_io.lua -- Ansible (and its apps) over crow's i2c bus.
--
-- The language core builds raw Teletype i2c packets (see lib/ops/hardware.lua
-- and lib/ops/ansible.lua); this module maps them onto crow ii calls.
--
-- The structure follows crow, not Teletype: where Teletype treats an Ansible
-- as one device reached at several i2c addresses, crow exposes each app as its
-- own ii module. Address -> module, verified with `crow.ii.help()`:
--
--   0x20 II_ANSIBLE_ADDR  ii.ansible          generic CV/TR
--   0x28 II_KR_ADDR       ii.kria
--   0x2A II_MP_ADDR       ii.meadowphysics
--   0x2C II_LV_ADDR       ii.levels
--   0x2E II_CY_ADDR       (none -- Cycles has no crow module)
--   0x24 II_MID_ADDR      (none -- Ansible MIDI mode)
--   0x26 II_ARP_ADDR      (none -- Ansible Arp mode)
--   0x50 ES               (none -- Earthsea, grid passthrough)
--
-- Every command name and argument list below was read from the crow itself
-- (`ii.<module>.help()`), never guessed: sending a wrong-but-plausible command
-- would move the wrong track silently, which is worse than not sending.
--
-- ARGUMENT SPECS. A Teletype packet is `{command, arg bytes...}`, and the
-- arguments are positional -- not always a channel and a value. `kria.position`
-- takes three, `kria.preset` takes one, `trigger_pulse` takes only a channel.
-- So each command carries a spec saying how to read its bytes off the wire and
-- what units crow wants:
--
--   'ch'       one byte, 0-based on the wire, 1-based for crow
--   'byte'     one byte, passed through unchanged
--   'word'     two bytes big-endian, passed through
--   'volts'    two bytes big-endian in Teletype's 0..16383 domain -> volts
--   'seconds'  two bytes big-endian in milliseconds -> seconds
--
-- 'ch' is only used where Teletype masks the value into 0..3 itself (the
-- generic CV/TR channels, and the per-app `cv` reads). The app commands pass
-- track and param numbers straight through, because Teletype and crow are both
-- forwarding to the same Ansible firmware.

local M = {}

M.BASE_ADDR = 0x20

--- ii.ansible -- verified with `crow.ii.ansible.help()`.
-- note `trigger_polarity` rather than the abbreviation, and `cv_offset`
-- rather than `cv_off`.
local ANSIBLE = {
  [1]  = { name = 'trigger',          args = { 'ch', 'byte' }, read = { 'ch' } },
  [2]  = { name = 'trigger_toggle',   args = { 'ch' } },
  [3]  = { name = 'trigger_pulse',    args = { 'ch' } },
  [4]  = { name = 'trigger_time',     args = { 'ch', 'seconds' }, read = { 'ch' } },
  [5]  = { name = 'trigger_polarity', args = { 'ch', 'byte' }, read = { 'ch' } },
  [6]  = { name = 'cv',               args = { 'ch', 'volts' }, read = { 'ch' } },
  [7]  = { name = 'cv_slew',          args = { 'ch', 'seconds' }, read = { 'ch' } },
  [8]  = { name = 'cv_offset',        args = { 'ch', 'volts' }, read = { 'ch' } },
  [9]  = { name = 'cv_set',           args = { 'ch', 'volts' } },
  [10] = { name = 'input',            read = { 'ch' } },
}

--- ii.kria -- verified with `crow.ii.kria.help()`.
-- `page`, `cue`, `clock`, `toggle_mute` and `direction` are write-only: crow
-- lists no matching `get`, so Teletype's read forms have nowhere to go.
local KRIA = {
  [0]  = { name = 'preset',      args = { 'byte' }, read = {} },
  [1]  = { name = 'pattern',     args = { 'byte' }, read = {} },
  [2]  = { name = 'scale',       args = { 'byte' }, read = {} },
  [3]  = { name = 'period',      args = { 'seconds' }, read = {} },
  [4]  = { name = 'position',    args = { 'byte', 'byte', 'byte' },
                                 read = { 'byte', 'byte' } },
  [5]  = { name = 'loop_start',  args = { 'byte', 'byte', 'byte' },
                                 read = { 'byte', 'byte' } },
  [6]  = { name = 'loop_length', args = { 'byte', 'byte', 'byte' },
                                 read = { 'byte', 'byte' } },
  [7]  = { name = 'reset',       args = { 'byte', 'byte' }, read = { 'byte' } },
  [8]  = { name = 'cv',          read = { 'ch' } },
  [9]  = { name = 'mute',        args = { 'byte', 'byte' }, read = { 'byte' } },
  [10] = { name = 'toggle_mute', args = { 'byte' } },
  [11] = { name = 'clock',       args = { 'byte' } },
  [12] = { name = 'page',        args = { 'byte' } },
  [13] = { name = 'cue',         args = { 'byte' } },
  [14] = { name = 'direction',   args = { 'byte', 'byte' } },
  [15] = { name = 'duration',    read = {} },
}

--- ii.meadowphysics -- verified with `crow.ii.meadowphysics.help()`
local MEADOWPHYSICS = {
  [0] = { name = 'preset', args = { 'byte' }, read = {} },
  [1] = { name = 'reset',  args = { 'byte' } },
  [2] = { name = 'stop',   args = { 'byte' }, read = {} },
  [3] = { name = 'scale',  args = { 'byte' }, read = {} },
  [4] = { name = 'period', args = { 'seconds' }, read = {} },
  [5] = { name = 'cv',     read = { 'ch' } },
}

--- ii.levels -- verified with `crow.ii.levels.help()`
local LEVELS = {
  [0] = { name = 'preset',         args = { 'byte' }, read = {} },
  [1] = { name = 'reset',          args = { 'byte' } },
  [2] = { name = 'position',       args = { 'byte' }, read = {} },
  [3] = { name = 'loop_start',     args = { 'byte' }, read = {} },
  [4] = { name = 'loop_length',    args = { 'byte' }, read = {} },
  [5] = { name = 'loop_direction', args = { 'byte' }, read = {} },
  [6] = { name = 'cv',             read = { 'ch' } },
}

M.DEVICES = {
  [0x20] = { module = 'ansible', commands = ANSIBLE },
  [0x28] = { module = 'kria', commands = KRIA },
  [0x2A] = { module = 'meadowphysics', commands = MEADOWPHYSICS },
  [0x2C] = { module = 'levels', commands = LEVELS },
  -- Cycles (0x2E), MIDI mode (0x24), Arp (0x26) and Earthsea (0x50) have no
  -- crow module; they fall through to raw_send.
}

--- resolve an i2c address to a device entry, or nil.
--
-- Only the addresses listed above resolve. Teletype computes expander
-- addresses as 0x20 + 2n, which puts the third and fourth Ansible at 0x24 and
-- 0x26 -- exactly where MIDI mode and Arp mode live, with colliding command
-- bytes (II_MID_SLEW and II_ANSIBLE_TR are both 1). Nothing in the packet can
-- tell them apart, so we do not guess: those addresses go out raw, byte for
-- byte, which is correct for either interpretation.
function M.device_for(addr)
  return M.DEVICES[addr]
end

-- --------------------------------------------------------------- conversions

local VOLT_SCALE = 1638.4   -- Teletype units per volt

function M.to_volts(raw) return raw / VOLT_SCALE end
function M.from_volts(v) return math.floor(v * VOLT_SCALE + 0.5) end

--- decode a packet's argument bytes according to `spec`.
-- `data` is the whole packet; arguments start at index 2.
function M.decode_args(spec, data)
  local args, pos = {}, 2
  for _, kind in ipairs(spec or {}) do
    if kind == 'ch' then
      args[#args + 1] = (data[pos] or 0) + 1     -- crow channels are 1-based
      pos = pos + 1
    elseif kind == 'byte' then
      args[#args + 1] = data[pos] or 0
      pos = pos + 1
    else
      local raw = ((data[pos] or 0) << 8) + (data[pos + 1] or 0)
      pos = pos + 2
      if kind == 'volts' then
        args[#args + 1] = M.to_volts(raw)
      elseif kind == 'seconds' then
        args[#args + 1] = raw / 1000
      else
        args[#args + 1] = raw
      end
    end
  end
  return args
end

--- convert a value arriving from crow back into Teletype's units
function M.from_crow(name, value)
  if name == 'cv' or name == 'cv_offset' then return M.from_volts(value) end
  if name == 'trigger_time' or name == 'cv_slew' or name == 'period'
      or name == 'duration' then
    return math.floor(value * 1000 + 0.5)
  end
  return math.floor(value + 0.5)
end

-- --------------------------------------------------------------- read cache

--- cached values from asynchronous reads, keyed "module:command:args"
M.cache = {}

local function cache_key(module, name, args)
  return module .. ':' .. name .. ':' .. table.concat(args or {}, ',')
end

--- record a value arriving from a crow ii event callback.
-- `args` is the argument list the request was made with, so a per-channel
-- read caches per channel.
function M.on_event(module, name, args, value)
  M.cache[cache_key(module, name, args)] = M.from_crow(name, value)
end

--- read the last known value and ask crow to refresh it.
-- Returns immediately -- the refreshed value lands on a later read.
function M.read(crow_ii, module, entry, args)
  if not entry.read then return 0 end        -- crow exposes no getter
  if crow_ii then
    crow_ii[module].get(entry.name, table.unpack(args))
  end
  return M.cache[cache_key(module, entry.name, args)] or 0
end

--- send one translated command
function M.send(crow_ii, module, name, args)
  if not crow_ii then return end
  crow_ii[module][name](table.unpack(args))
end

-- --------------------------------------------------------- unmapped packets

M.unmapped = 0
M.unmapped_examples = {}

--- Raw i2c transport, used for the families crow has no module for: Cycles,
--- Arp mode, MIDI mode and the grid/arc passthrough.
--
-- crow exposes `ii.raw` (confirmed present on the device). We send the packet
-- exactly as a hardware Teletype would put it on the bus, so those ops keep
-- working without any per-command mapping at all.
--
-- `M.raw_style` selects how the bytes are passed:
--   'table'    ii.raw(addr, {b1, b2, ...})
--   'varargs'  ii.raw(addr, b1, b2, ...)
M.raw_style = 'table'

--- Prefer the raw transport for writes.
--
-- This is the default because it is strictly more faithful. A raw send puts
-- the same bytes on the bus that a hardware Teletype would, so there is no
-- command-name mapping to get wrong and no unit conversion to infer -- the
-- values are already in the Ansible's own format. It also makes the ops crow
-- has no module for (Cycles, Arp, MIDI mode, grid passthrough) work with no
-- extra machinery, and resolves the 0x24/0x26 address collision by not having
-- to take a position on it.
--
-- Reads still go through the named `get()` calls, because `ii.raw` has no
-- request/response form.
--
-- Set false to use the named command tables for writes instead -- needed if a
-- crow firmware turns out not to have `ii.raw`.
M.prefer_raw = true

--- install the raw transport against a live crow
function M.enable_raw(crow_ii)
  if not crow_ii then M.raw_send = nil return end
  M.raw_send = function(addr, data)
    if M.raw_style == 'varargs' then
      crow_ii.raw(addr, table.unpack(data))
    else
      crow_ii.raw(addr, data)
    end
  end
end

function M.disable_raw() M.raw_send = nil end

function M.note_unmapped(addr, data)
  M.unmapped = M.unmapped + 1
  if #M.unmapped_examples < 8 then
    M.unmapped_examples[#M.unmapped_examples + 1] =
      ('%02x:%s'):format(addr, table.concat(data, ','))
  end
end

return M
