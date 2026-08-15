-- int16.lua
--
-- teletype's entire value domain is int16. every op reads and writes int16, and
-- a good deal of scene behaviour depends on the exact overflow/clamp edges, so
-- the arithmetic contract lives here rather than being open-coded per op.
--
-- reference: teletype/src/helpers.c, teletype/src/command.h

local int16 = {}

int16.MIN = -32768
int16.MAX = 32767

--- wrap a lua integer into int16, two's complement.
-- this is what C gets for free on assignment to an int16_t.
function int16.wrap(v)
  v = v & 0xffff
  return v >= 0x8000 and v - 0x10000 or v
end

--- clamp to the int16 range without wrapping.
-- MATCH_NUMBER in match_token.rl clamps rather than wraps when a literal is
-- out of range, so parsing "99999" yields 32767, not -31073.
function int16.clamp(v)
  if v > int16.MAX then return int16.MAX end
  if v < int16.MIN then return int16.MIN end
  return v
end

--- reinterpret a uint16 bit pattern as int16.
function int16.from_u16(v)
  v = v & 0xffff
  return v >= 0x8000 and v - 0x10000 or v
end

--- reinterpret an int16 as its uint16 bit pattern.
function int16.to_u16(v)
  return v & 0xffff
end

--- C integer division: truncates toward zero.
-- lua's // floors, which differs for negative operands: -7 // 2 is -4 in lua
-- but -3 in C. teletype's DIV op is C semantics.
function int16.idiv(a, b)
  local q = a // b
  -- correct the floor back to a truncation when the result is negative and
  -- the division was not exact
  if q < 0 and q * b ~= a then q = q + 1 end
  return q
end

--- C remainder: sign follows the dividend.
function int16.imod(a, b)
  return a - int16.idiv(a, b) * b
end

return int16
