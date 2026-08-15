-- helpers.lua
--
-- direct port of teletype/src/helpers.c. these look like trivia but scene
-- compatibility depends on their exact edge behaviour -- normalise_value in
-- particular backs O, DRUNK, pattern indices and the turtle fences.

local int16 = require 'int16'

local helpers = {}

--- clamp or wrap a value into [min, max].
-- teletype/src/helpers.c:8. note the asymmetry: when wrapping, a value below
-- min becomes max and a value above max becomes min -- it wraps to the far
-- edge, it does not modulo.
function helpers.normalise_value(min, max, wrap, value)
  if value >= min and value <= max then return value end
  if wrap ~= 0 then
    if value < min then return max else return min end
  else
    if value < min then return min else return max end
  end
end

--- reverse the low `bits_to_reverse` bits of a value.
-- teletype/src/helpers.c:96, backs the BREV op.
function helpers.bit_reverse(unreversed, bits_to_reverse)
  local reversed = 0
  for i = 0, bits_to_reverse - 1 do
    if (unreversed & (1 << i)) ~= 0 then
      reversed = reversed | (1 << ((bits_to_reverse - 1) - i))
    end
  end
  return int16.wrap(reversed)
end

--- parse a bit string least-significant-digit-first.
-- teletype/src/helpers.c:105. this is what makes "R1000" == 1 rather than 8:
-- the leftmost character is bit 0.
--
-- the C returns int16_t, so a full 16-bit run sums to 65535 and truncates to
-- -1. that truncation has to happen here rather than at the call site, because
-- MATCH_NUMBER applies the bit-reversed result *after* its own cast.
function helpers.rev_bitstring_to_int(token)
  local value = 0
  for i = 1, #token do
    if token:sub(i, i) == '1' then
      value = value + (1 << (i - 1))
    end
  end
  return int16.wrap(value)
end

--- format a value as an uppercase hex literal, "X" prefixed.
-- teletype/src/helpers.c:114. leading zeros are suppressed, and a zero value
-- renders as "X0".
function helpers.itoa_hex(value)
  value = int16.to_u16(value)
  local out, started = {}, false
  for i = 3, 0, -1 do
    local v = (value >> (i << 2)) & 0xf
    if started or v ~= 0 then
      out[#out + 1] = string.format('%X', v)
      started = true
    end
  end
  if not started then out[1] = '0' end
  return 'X' .. table.concat(out)
end

--- format a value as a binary literal, "B" prefixed, MSB first.
-- teletype/src/helpers.c:132.
function helpers.itoa_bin(value)
  value = int16.to_u16(value)
  local out, started = {}, false
  for i = 15, 0, -1 do
    local v = (value >> i) & 1
    if started or v ~= 0 then
      out[#out + 1] = tostring(v)
      started = true
    end
  end
  if not started then out[1] = '0' end
  return 'B' .. table.concat(out)
end

--- format a value as a bit-reversed binary literal, "R" prefixed, LSB first.
-- teletype/src/helpers.c:148. the C version writes all 16 bits then truncates
-- after the last '1', so trailing zeros are dropped and 0 renders as "R0".
function helpers.itoa_rbin(value)
  value = int16.to_u16(value)
  local bits = {}
  for i = 0, 15 do
    bits[i + 1] = tostring((value >> i) & 1)
  end
  local last = 0
  for i = 16, 1, -1 do
    if bits[i] == '1' then last = i break end
  end
  if last == 0 then return 'R0' end
  return 'R' .. table.concat(bits, '', 1, last)
end

return helpers
