-- ops/ansible.lua -- port of teletype/src/ops/ansible.c
--
-- Remote control of a monome Ansible over i2c: its four apps (Kria, Meadow-
-- physics, Levels, Cycles), the MIDI and Arp modes, and grid/arc passthrough.
--
-- Every op here is a packet builder. Each Ansible app answers on its own i2c
-- address, and a "get" is the same command byte with II_GET set, followed by
-- a read. That regularity means the whole family is a table rather than 53
-- hand-written functions -- which also makes it obvious that the bytes match
-- the reference.
--
-- On norns these packets go out through crow's ii bus (lib/io/ansible_io).

local exec = require 'exec'
local int16 = require 'int16'
local registry = require 'ops.registry'

local impl = registry.impl

-- libavr32/src/ii.h
local ADDR = {
  ANSIBLE = 0x20, MID = 0x24, ARP = 0x26,
  KR = 0x28, MP = 0x2A, LV = 0x2C, CY = 0x2E,
  ES = 0x50,
}
local II_GET = 128

-- command bytes, per family
local KR = { PRESET = 0, PATTERN = 1, SCALE = 2, PERIOD = 3, POS = 4,
             LOOP_ST = 5, LOOP_LEN = 6, RESET = 7, CV = 8, MUTE = 9,
             TMUTE = 10, CLK = 11, PAGE = 12, CUE = 13, DIR = 14,
             DURATION = 15 }
local MP = { PRESET = 0, RESET = 1, STOP = 2, SCALE = 3, PERIOD = 4, CV = 5 }
local LV = { PRESET = 0, RESET = 1, POS = 2, L_ST = 3, L_LEN = 4, L_DIR = 5,
             CV = 6 }
local CY = { PRESET = 0, RESET = 1, POS = 2, REV = 3, CV = 4 }
local MID = { SLEW = 1, SHIFT = 2 }
local ARP = { STYLE = 0, HOLD = 1, RPT = 2, GATE = 3, DIV = 4, ROT = 5,
              SLEW = 6, PULSE = 7, RESET = 8, SHIFT = 9, FILL = 10, ER = 11 }
local ANSIBLE = { APP = 15 }
local GRID = { KEY = 16, LED = 17 }
local ARC = { ENC = 24, LED = 25 }

local function byte(v) return v & 0xff end
local function hi(v) return (int16.to_u16(v) >> 8) & 0xff end
local function lo(v) return int16.to_u16(v) & 0xff end

--- read a value back from `addr` -- one byte, or two big-endian
local function read(addr, width)
  local d = exec.io.ii_rx(addr, width)
  if width == 2 then
    return int16.wrap(((d[1] or 0) << 8) + (d[2] or 0))
  end
  return d[1] or 0
end

-- ---------------------------------------------------------------- generators

--- a write-only op: pop `argspec` values and send them after the command byte.
-- `argspec` is a list of 'b' (one byte) or 'w' (two bytes, big-endian).
local function setter(name, addr, cmd, argspec)
  return function(_ss, _es, cs)
    local d = { cmd }
    for _, kind in ipairs(argspec) do
      local v = cs:pop()
      if kind == 'w' then
        d[#d + 1] = hi(v); d[#d + 1] = lo(v)
      else
        d[#d + 1] = byte(v)
      end
    end
    exec.io.ii_tx(addr, d)
  end
end

--- a read op: send the command with II_GET plus any selector bytes, then read.
-- `width` is 1 or 2.
--
-- The 16-bit getters declare a two-byte buffer in the C but transmit only one
-- byte -- the second slot exists to receive the reply, not to be sent. So the
-- request is always the command plus its selectors, nothing more.
local function getter(addr, cmd, args, width, decrement)
  return function(_ss, _es, cs)
    local d = { cmd | II_GET }
    for _ = 1, args do
      local v = cs:pop()
      -- the CV and duration getters are 1-indexed and mask to two bits
      if decrement then v = (v - 1) & 0x3 end
      d[#d + 1] = byte(v)
    end
    exec.io.ii_tx(addr, d)
    cs:push(read(addr, width))
  end
end

--- declare an op from a compact spec. `get` and `set` are optional.
local function decl(name, get, set)
  impl(name, get, set)
end

-- ------------------------------------------------------------------- Kria

decl('KR.PRE', getter(ADDR.KR, KR.PRESET, 0, 1), setter(nil, ADDR.KR, KR.PRESET, {'b'}))
decl('KR.PAT', getter(ADDR.KR, KR.PATTERN, 0, 1), setter(nil, ADDR.KR, KR.PATTERN, {'b'}))
decl('KR.SCALE', getter(ADDR.KR, KR.SCALE, 0, 1), setter(nil, ADDR.KR, KR.SCALE, {'b'}))
-- PERIOD is 16-bit, and its request carries a pad byte
decl('KR.PERIOD', getter(ADDR.KR, KR.PERIOD, 0, 2), setter(nil, ADDR.KR, KR.PERIOD, {'w'}))
decl('KR.POS', getter(ADDR.KR, KR.POS, 2, 1), setter(nil, ADDR.KR, KR.POS, {'b','b','b'}))
decl('KR.L.ST', getter(ADDR.KR, KR.LOOP_ST, 2, 1), setter(nil, ADDR.KR, KR.LOOP_ST, {'b','b','b'}))
decl('KR.L.LEN', getter(ADDR.KR, KR.LOOP_LEN, 2, 1), setter(nil, ADDR.KR, KR.LOOP_LEN, {'b','b','b'}))
decl('KR.RES', setter(nil, ADDR.KR, KR.RESET, {'b','b'}))
decl('KR.CV', getter(ADDR.KR, KR.CV, 1, 2, true))
decl('KR.MUTE', getter(ADDR.KR, KR.MUTE, 1, 1), setter(nil, ADDR.KR, KR.MUTE, {'b','b'}))
decl('KR.TMUTE', setter(nil, ADDR.KR, KR.TMUTE, {'b'}))
decl('KR.CLK', setter(nil, ADDR.KR, KR.CLK, {'b'}))
decl('KR.PG', getter(ADDR.KR, KR.PAGE, 0, 1), setter(nil, ADDR.KR, KR.PAGE, {'b'}))
decl('KR.CUE', getter(ADDR.KR, KR.CUE, 0, 1), setter(nil, ADDR.KR, KR.CUE, {'b'}))
decl('KR.DIR', getter(ADDR.KR, KR.DIR, 1, 1), setter(nil, ADDR.KR, KR.DIR, {'b','b'}))
decl('KR.DUR', getter(ADDR.KR, KR.DURATION, 1, 2, true))

-- ------------------------------------------------------- Meadowphysics

decl('ME.PRE', getter(ADDR.MP, MP.PRESET, 0, 1), setter(nil, ADDR.MP, MP.PRESET, {'b'}))
decl('ME.RES', setter(nil, ADDR.MP, MP.RESET, {'b'}))
decl('ME.STOP', setter(nil, ADDR.MP, MP.STOP, {'b'}))
decl('ME.SCALE', getter(ADDR.MP, MP.SCALE, 0, 1), setter(nil, ADDR.MP, MP.SCALE, {'b'}))
decl('ME.PERIOD', getter(ADDR.MP, MP.PERIOD, 0, 2), setter(nil, ADDR.MP, MP.PERIOD, {'w'}))
decl('ME.CV', getter(ADDR.MP, MP.CV, 1, 2, true))

-- --------------------------------------------------------------- Levels

decl('LV.PRE', getter(ADDR.LV, LV.PRESET, 0, 1), setter(nil, ADDR.LV, LV.PRESET, {'b'}))
decl('LV.RES', setter(nil, ADDR.LV, LV.RESET, {'b'}))
decl('LV.POS', getter(ADDR.LV, LV.POS, 0, 1), setter(nil, ADDR.LV, LV.POS, {'b'}))
decl('LV.L.ST', getter(ADDR.LV, LV.L_ST, 0, 1), setter(nil, ADDR.LV, LV.L_ST, {'b'}))
decl('LV.L.LEN', getter(ADDR.LV, LV.L_LEN, 0, 1), setter(nil, ADDR.LV, LV.L_LEN, {'b'}))
decl('LV.L.DIR', getter(ADDR.LV, LV.L_DIR, 0, 1), setter(nil, ADDR.LV, LV.L_DIR, {'b'}))
decl('LV.CV', getter(ADDR.LV, LV.CV, 1, 2, true))

-- --------------------------------------------------------------- Cycles

decl('CY.PRE', getter(ADDR.CY, CY.PRESET, 0, 1), setter(nil, ADDR.CY, CY.PRESET, {'b'}))
decl('CY.RES', setter(nil, ADDR.CY, CY.RESET, {'b'}))
decl('CY.POS', getter(ADDR.CY, CY.POS, 1, 1), setter(nil, ADDR.CY, CY.POS, {'b','b'}))
decl('CY.REV', setter(nil, ADDR.CY, CY.REV, {'b'}))
decl('CY.CV', getter(ADDR.CY, CY.CV, 1, 2, true))

-- ------------------------------------------------------------ MIDI mode

decl('MID.SHIFT', setter(nil, ADDR.MID, MID.SHIFT, {'w'}))
decl('MID.SLEW', setter(nil, ADDR.MID, MID.SLEW, {'w'}))

-- ------------------------------------------------------------- Arp mode

decl('ARP.STY', setter(nil, ADDR.ARP, ARP.STYLE, {'b'}))
decl('ARP.HLD', setter(nil, ADDR.ARP, ARP.HOLD, {'b'}))
decl('ARP.RPT', setter(nil, ADDR.ARP, ARP.RPT, {'b','b','w'}))
decl('ARP.GT', setter(nil, ADDR.ARP, ARP.GATE, {'b','b'}))
decl('ARP.DIV', setter(nil, ADDR.ARP, ARP.DIV, {'b','b'}))
decl('ARP.RES', setter(nil, ADDR.ARP, ARP.RESET, {'b'}))
decl('ARP.SHIFT', setter(nil, ADDR.ARP, ARP.SHIFT, {'b','w'}))
decl('ARP.SLEW', setter(nil, ADDR.ARP, ARP.SLEW, {'b','w'}))
decl('ARP.FIL', setter(nil, ADDR.ARP, ARP.FILL, {'b','b'}))
decl('ARP.ROT', setter(nil, ADDR.ARP, ARP.ROT, {'b','w'}))
decl('ARP.ER', setter(nil, ADDR.ARP, ARP.ER, {'b','b','b','w'}))

-- ------------------------------------------------- grid / arc passthrough
-- These broadcast to every app that might be listening and read back from
-- each in turn, so the last responder wins. That is how the C does it: with
-- only one Ansible on the bus, only one address actually answers.

local GRID_TARGETS = { ADDR.KR, ADDR.MP, ADDR.ES }
local ARC_TARGETS = { ADDR.LV, ADDR.CY }
-- the three orders genuinely differ in the C; KR and MP swap between them
local APP_GET_TX = { ADDR.ANSIBLE, ADDR.LV, ADDR.CY, ADDR.MP, ADDR.KR,
                     ADDR.MID, ADDR.ARP, ADDR.ES }
local APP_GET_RX = { ADDR.ANSIBLE, ADDR.LV, ADDR.CY, ADDR.KR, ADDR.MP,
                     ADDR.MID, ADDR.ARP, ADDR.ES }
local APP_SET_TX = { ADDR.ANSIBLE, ADDR.LV, ADDR.CY, ADDR.KR, ADDR.MP,
                     ADDR.MID, ADDR.ARP, ADDR.ES }

--- broadcast `d` to every target, then read one byte from each and return the
--- last. matches the C's reuse of a single buffer across the reads.
local function broadcast_query(targets, d)
  for _, addr in ipairs(targets) do exec.io.ii_tx(addr, d) end
  local last = 0
  for _, addr in ipairs(targets) do last = read(addr, 1) end
  return last
end

impl('ANS.G.LED', function(_ss, _es, cs)
  local x, y = cs:pop(), cs:pop()
  cs:push(broadcast_query(GRID_TARGETS,
    { GRID.LED | II_GET, byte(x), byte(y) }))
end)

impl('ANS.G',
  function(_ss, _es, cs)
    local x, y = cs:pop(), cs:pop()
    -- DIVERGENCE: the C declares a three-byte buffer and transmits four, so
    -- the last byte is uninitialised stack. On this build it happens to alias
    -- `y`, but that is a stack-layout accident, not semantics -- we send a
    -- deterministic 0. The length of four is real and is preserved.
    -- see docs/differences.md.
    local d = { GRID.KEY | II_GET, byte(x), byte(y), 0 }
    cs:push(broadcast_query(GRID_TARGETS, d))
  end,
  function(_ss, _es, cs)
    local x, y, z = cs:pop(), cs:pop(), cs:pop()
    local d = { GRID.KEY, byte(x), byte(y), byte(z) }
    for _, addr in ipairs(GRID_TARGETS) do exec.io.ii_tx(addr, d) end
  end)

--- a press and release in one op
impl('ANS.G.P', function(_ss, _es, cs)
  local x, y = cs:pop(), cs:pop()
  local down = { GRID.KEY, byte(x), byte(y), 1 }
  for _, addr in ipairs(GRID_TARGETS) do exec.io.ii_tx(addr, down) end
  local up = { GRID.KEY, byte(x), byte(y), 0 }
  for _, addr in ipairs(GRID_TARGETS) do exec.io.ii_tx(addr, up) end
end)

impl('ANS.A.LED', function(_ss, _es, cs)
  local n, i = cs:pop(), cs:pop()
  cs:push(broadcast_query(ARC_TARGETS, { ARC.LED | II_GET, byte(n), byte(i) }))
end)

impl('ANS.A', function(_ss, _es, cs)
  local n, delta = cs:pop(), cs:pop()
  local d = { ARC.ENC, byte(n), byte(delta) }
  for _, addr in ipairs(ARC_TARGETS) do exec.io.ii_tx(addr, d) end
end)

impl('ANS.APP',
  function(_ss, _es, cs)
    local d = { ANSIBLE.APP | II_GET }
    for _, addr in ipairs(APP_GET_TX) do exec.io.ii_tx(addr, d) end
    local last = 0
    -- the read order differs from the write order in the C; kept as-is
    for _, addr in ipairs(APP_GET_RX) do last = read(addr, 1) end
    cs:push(last)
  end,
  function(_ss, _es, cs)
    local n = cs:pop()
    local d = { ANSIBLE.APP, byte(n) }
    for _, addr in ipairs(APP_SET_TX) do exec.io.ii_tx(addr, d) end
  end)
