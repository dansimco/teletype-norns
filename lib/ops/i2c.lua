-- ops/i2c.lua -- port of teletype/src/ops/i2c.c
--
-- The generic i2c escape hatch: IIA selects a target address, then IIS*/IIQ*/
-- IIB* send a command with 0-3 word or byte arguments and optionally read a
-- word or byte back.
--
-- This matters more here than on hardware. The port implements the Ansible
-- family natively, but every other i2c device (telex, disting, just friends,
-- W/, ER-301, …) is out of scope -- so these ops are how a scene reaches one
-- anyway, as long as lib/io can put the bytes on crow's ii bus.

local exec = require 'exec'
local int16 = require 'int16'
local registry = require 'ops.registry'

local impl = registry.impl

--- send a command byte followed by `count` 16-bit words, big-endian.
-- i2c.c:76. Nothing is sent when no address has been selected.
local function send_words(ss, cs, count)
  local d = { cs:pop() & 0xff }
  for _ = 1, count do
    local value = int16.to_u16(cs:pop())
    d[#d + 1] = (value >> 8) & 0xff
    d[#d + 1] = value & 0xff
  end
  if ss.i2c_op_address == -1 then return end
  exec.io.ii_tx(ss.i2c_op_address, d)
end

--- as above but with single-byte arguments. i2c.c:93
local function send_bytes(ss, cs, count)
  local d = { cs:pop() & 0xff }
  for _ = 1, count do
    d[#d + 1] = int16.to_u16(cs:pop()) & 0xff
  end
  if ss.i2c_op_address == -1 then return end
  exec.io.ii_tx(ss.i2c_op_address, d)
end

local function query_word(ss, cs)
  if ss.i2c_op_address == -1 then cs:push(0) return end
  local b = exec.io.ii_rx(ss.i2c_op_address, 2)
  cs:push(int16.wrap(((b[1] or 0) << 8) + (b[2] or 0)))
end

local function query_byte(ss, cs)
  if ss.i2c_op_address == -1 then cs:push(0) return end
  local b = exec.io.ii_rx(ss.i2c_op_address, 1)
  cs:push(b[1] or 0)
end

-- the selected address; anything above 0x7f clears it back to "unset"
impl('IIA',
  function(ss, _es, cs) cs:push(ss.i2c_op_address) end,
  function(ss, _es, cs)
    local address = int16.to_u16(cs:pop())
    ss.i2c_op_address = address > 0x7f and -1 or address
  end)

-- send only
for count = 0, 3 do
  impl(count == 0 and 'IIS' or ('IIS%d'):format(count),
    function(ss, _es, cs) send_words(ss, cs, count) end)
end
for count = 1, 3 do
  impl(('IISB%d'):format(count),
    function(ss, _es, cs) send_bytes(ss, cs, count) end)
end

-- send then read a word back
for count = 0, 3 do
  impl(count == 0 and 'IIQ' or ('IIQ%d'):format(count),
    function(ss, _es, cs) send_words(ss, cs, count); query_word(ss, cs) end)
end
for count = 1, 3 do
  impl(('IIQB%d'):format(count),
    function(ss, _es, cs) send_bytes(ss, cs, count); query_word(ss, cs) end)
end

-- send then read a byte back
for count = 0, 3 do
  impl(count == 0 and 'IIB' or ('IIB%d'):format(count),
    function(ss, _es, cs) send_words(ss, cs, count); query_byte(ss, cs) end)
end
for count = 1, 3 do
  impl(('IIBB%d'):format(count),
    function(ss, _es, cs) send_bytes(ss, cs, count); query_byte(ss, cs) end)
end
