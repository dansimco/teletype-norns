-- ops/pitch.lua -- note, voltage and quantisation ops
-- port of the pitch half of teletype/src/ops/maths.c
--
-- The voltage domain: 0..16383 spans 0..10V, so 1V is 1638.4 units and a
-- semitone is 1638.4/12. table_n (libavr32's ET) holds 128 semitones on that
-- scale; table_v holds whole volts; table_vv interpolates hundredths.

local int16 = require 'int16'
local helpers = require 'helpers'
local registry = require 'ops.registry'
local st = require 'state'
local T = require 'tables'

local impl = registry.impl

local NB_NBX_SCALES = st.NB_NBX_SCALES
local NB_SCALE_PRESETS = 20   -- #table_n_b

-- teletype/src/ops/maths.c:337
local function note_number_to_volts(note_in)
  if note_in < 0 then
    if note_in < -127 then note_in = -127 end
    return -T.table_n[-note_in]
  else
    if note_in > 127 then note_in = 127 end
    return T.table_n[note_in]
  end
end

--- nearest note number for a voltage. binary search over table_n, choosing
--- the closer neighbour on a tie-break upward. teletype/src/ops/maths.c:300
local function volts_to_note_number(v_in)
  -- the negation is an int16 one, so -32768 stays negative and falls into the
  -- `target <= table_n[0]` case below, returning 0
  local target = v_in < 0 and int16.wrap(-v_in) or v_in
  local length = 128

  if target <= T.table_n[0] then return 0 end
  if target >= T.table_n[length - 1] then return length - 1 end

  local i, j, mid = 0, length, 0
  local function signed(n) return v_in < 0 and -n or n end

  while i < j do
    mid = (i + j) // 2
    if T.table_n[mid] == target then return signed(mid) end
    if target < T.table_n[mid] then
      if mid > 0 and target > T.table_n[mid - 1] then
        if (target - T.table_n[mid - 1]) >= (T.table_n[mid] - target) then
          return signed(mid)
        else
          return signed(mid - 1)
        end
      end
      j = mid
    else
      if mid < length - 1 and target < T.table_n[mid + 1] then
        if (target - T.table_n[mid]) >= (T.table_n[mid + 1] - target) then
          return signed(mid + 1)
        else
          return signed(mid)
        end
      end
      i = mid + 1
    end
  end
  return signed(mid)
end

-- teletype/src/ops/maths.c:349 -- a N.S scale as a 12-bit mask, LSB = root
local function scale_n_s_to_bitmask(scale_n_s)
  scale_n_s = int16.imod(scale_n_s, 9)
  local bits = 0
  for i = 0, 6 do
    bits = bits | (1 << T.table_n_s[scale_n_s][i])
  end
  return bits
end

-- teletype/src/ops/maths.c:364 -- a stacked-thirds chord from a N.S scale
local function chord_n_s_to_bitmask(scale_n_s, degree, voices)
  scale_n_s = int16.imod(scale_n_s, 9)
  degree = int16.imod(degree, 7)
  voices = helpers.normalise_value(1, 7, 0, voices)
  local bits = 0
  for _ = 1, voices do
    bits = bits | (1 << T.table_n_s[scale_n_s][degree])
    degree = (degree + 2) % 7
  end
  return bits
end

-- teletype/src/ops/maths.c:383 -- walk a scale mask to the nth degree
local function get_degree_in_bitmask_scale(scale_bits, transpose, degree)
  local note = 0
  if degree > 0 then
    for i = 0, 127 do
      if (scale_bits >> (i % 12)) & 1 == 1 then
        degree = degree - 1
        if degree == 0 then break end
      end
      note = note + 1
    end
  else
    degree = degree - 1
    for i = 0, 127 do
      if (scale_bits >> (11 - (i % 12))) & 1 == 1 then
        degree = degree + 1
        if degree == 0 then break end
      end
      note = note - 1
    end
    note = note - 1
  end
  note = note + transpose
  -- DIVERGENCE: this lookup is unclamped in the C, unlike
  -- note_number_to_volts, so a degree or root that pushes note outside
  -- 0..127 reads past table_n. we clamp to the table's range instead.
  -- see docs/differences.md.
  if note > 0 then return T.table_n[note > 127 and 127 or note] end
  note = -note
  return -T.table_n[note > 127 and 127 or note]
end

-- teletype/src/ops/maths.c:412 -- snap a voltage to the nearest scale pitch
local function quantize_to_bitmask_scale(scale_bits, transpose, v_in)
  if scale_bits == 0 then return v_in end

  v_in = helpers.normalise_value(-T.table_n[127], T.table_n[127], 0, v_in)

  -- negatives are lifted by 11 octaves so the modulo below works on a
  -- positive value, then dropped again at the end
  local sign_offset = v_in < 0 and 18022 or 0
  v_in = v_in + sign_offset

  local octave_in = int16.idiv(v_in, T.table_n[12])
  if v_in <= 18021 and v_in >= 18018 then octave_in = 10 end  -- precision fix
  local semitones_in = int16.imod(v_in, T.table_n[12])
  transpose = int16.imod(transpose, T.table_n[12])

  local dist_nearest, note_nearest = int16.MAX, int16.MAX
  for i = 0, 11 do
    if (scale_bits & (1 << i)) ~= 0 then
      for j = -2, 2 do
        local try_note = T.table_n[i] + transpose + (j * T.table_n[12])
        local try_distance = try_note - semitones_in
        if try_distance < 0 then try_distance = -try_distance end
        if try_distance < dist_nearest then
          dist_nearest = try_distance
          note_nearest = try_note
        end
      end
    end
  end

  return (note_nearest + T.table_n[octave_in * 12]) - sign_offset
end

-- basic conversions ----------------------------------------------------------

impl('N', function(_ss, _es, cs)
  cs:push(note_number_to_volts(cs:pop()))
end)

impl('VN', function(_ss, _es, cs)
  cs:push(volts_to_note_number(cs:pop()))
end)

impl('V', function(_ss, _es, cs)
  local a = cs:pop()
  if a > 10 then a = 10 elseif a < -10 then a = -10 end
  if a < 0 then cs:push(-T.table_v[-a]) else cs:push(T.table_v[a]) end
end)

impl('VV', function(_ss, _es, cs)
  local a = cs:pop()
  local negative = 1
  if a < 0 then negative = -1; a = -a end
  if a > 1000 then a = 1000 end
  cs:push(negative * (T.table_v[a // 100] + T.table_vv[a % 100]))
end)

--- 1V/oct to Hz/V, for MS-20 style oscillators. teletype/src/ops/maths.c:1003
impl('HZ', function(_ss, _es, cs)
  local v_in = cs:pop()
  local note, hz, interpolate = 0, 0, 0.0

  if v_in < 0 then
    v_in = -v_in
    for i = 127, 0, -1 do
      if v_in <= T.table_n[i] then note = i end
    end
    -- DIVERGENCE: when |v_in| exceeds table_n[127] no index matches and note
    -- stays 0, so the C reads table_n[-1] -- an out-of-bounds read whose value
    -- depends on what the linker put before the table. we skip the
    -- interpolation instead, which is deterministic. see docs/differences.md.
    if note > 0 then
      local delta_total = T.table_n[note] - T.table_n[note - 1]
      local delta = T.table_n[note] - v_in
      interpolate = delta / delta_total
    end
    note = -note
  else
    for i = 0, 127 do
      if v_in >= T.table_n[i] then note = i end
    end
    if note < 128 then
      local delta_total = (T.table_n[note + 1] or T.table_n[127]) - T.table_n[note]
      local delta = v_in - T.table_n[note]
      if delta_total ~= 0 then interpolate = delta / delta_total end
    end
  end

  note = note + 36  -- table_hzv is offset three octaves down

  if note < 0 then
    hz = T.table_hzv[0]
  elseif note >= 76 then
    hz = T.table_hzv[75]
  elseif note < 75 then
    hz = T.table_hzv[note]
      + (T.table_hzv[note + 1] - T.table_hzv[note]) * interpolate
  else
    hz = T.table_hzv[note]
  end

  -- the C assigns a float to an int16_t, which truncates toward zero
  cs:push(int16.wrap(hz >= 0 and math.floor(hz) or -math.floor(-hz)))
end)

--- just intonation ratio, normalised to 1V. teletype/src/ops/maths.c:898
impl('JI', function(_ss, _es, cs)
  local prime = { 2, 3, 5, 7, 11, 13 }
  local ji_const = { 6554, 10388, 15218, 18399, 22673, 24253 }
  local result = 0
  local n = cs:pop(); n = n < 0 and -n or n
  local d = cs:pop(); d = d < 0 and -d or d

  if n == 0 or d == 0 then cs:push(0) return end

  -- factor the numerator, adding a constant per prime factor
  for p = 1, 7 do
    if n == 1 then break end
    if p == 7 then cs:push(0) return end   -- did not fully factor
    local quotient = n // prime[p]
    while n == quotient * prime[p] do
      result = result + ji_const[p]
      n = quotient
      quotient = n // prime[p]
    end
  end
  -- and subtract for the denominator
  for p = 1, 7 do
    if d == 1 then break end
    if p == 7 then cs:push(0) return end
    local quotient = d // prime[p]
    while d == quotient * prime[p] do
      result = result - ji_const[p]
      d = quotient
      quotient = d // prime[p]
    end
  end

  cs:push((result + 2) >> 2)
end)

-- quantisation ---------------------------------------------------------------

impl('QT', function(_ss, _es, cs)
  -- rounds rather than quantises for negatives, as the C comment notes
  local b, a = cs:pop(), cs:pop()
  if a == 0 then cs:push(0) return end
  -- c, d and e are int16_t locals in the C, so the candidate above the input
  -- can overflow and wrap. `QT 32767 2` relies on it: e becomes -32768, the
  -- distance to it is huge, and the lower candidate wins.
  local c = int16.wrap(int16.idiv(b, a))
  local d = int16.wrap(c * a)
  local e = int16.wrap((c + 1) * a)
  -- the distances themselves are computed as promoted ints, not truncated
  local dd = b - d; if dd < 0 then dd = -dd end
  local de = b - e; if de < 0 then de = -de end
  cs:push(dd < de and d or e)
end)

impl('QT.S', function(_ss, _es, cs)
  local v_in = cs:pop()
  local transpose = cs:pop()
  local scale = int16.imod(cs:pop(), 9)
  if scale < 0 then scale = 9 + scale end
  cs:push(quantize_to_bitmask_scale(scale_n_s_to_bitmask(scale), transpose, v_in))
end)

impl('QT.CS', function(_ss, _es, cs)
  local v_in = cs:pop()
  local transpose = cs:pop()
  local scale = int16.imod(cs:pop(), 9)
  if scale < 0 then scale = 9 + scale end
  local degree = cs:pop() - 1
  local voices = helpers.normalise_value(1, 7, 0, cs:pop())
  local mask = chord_n_s_to_bitmask(scale, degree, voices)
  cs:push(quantize_to_bitmask_scale(mask, transpose, v_in))
end)

impl('QT.B', function(ss, _es, cs)
  local v_in = cs:pop()
  local mask = ss.variables.n_scale_bits[0]
  local transpose = note_number_to_volts(ss.variables.n_scale_root[0])
  cs:push(quantize_to_bitmask_scale(mask, transpose, v_in))
end)

impl('QT.BX', function(ss, _es, cs)
  local scale_nb = cs:pop()
  if scale_nb < 0 then scale_nb = 0 end
  if scale_nb > NB_NBX_SCALES - 1 then scale_nb = NB_NBX_SCALES - 1 end
  local v_in = cs:pop()
  local mask = ss.variables.n_scale_bits[scale_nb]
  local transpose = note_number_to_volts(ss.variables.n_scale_root[scale_nb])
  cs:push(quantize_to_bitmask_scale(mask, transpose, v_in))
end)

-- scale/chord note lookup ----------------------------------------------------

--- shared tail: apply a semitone transposition to a root note number
local function push_transposed(cs, root, transpose)
  if root < 0 then
    if root < -127 then root = -127 end
    cs:push(-T.table_n[-root + transpose])
  else
    if root > 127 then root = 127 end
    cs:push(T.table_n[root + transpose])
  end
end

impl('N.S', function(_ss, _es, cs)
  local root = cs:pop()
  local scale = int16.imod(cs:pop(), 9)
  if scale < 0 then scale = 9 + scale end
  local degree = int16.imod(cs:pop() - 1, 7)
  if degree < 0 then degree = 7 + degree end
  push_transposed(cs, root, T.table_n_s[scale][degree])
end)

impl('N.C', function(_ss, _es, cs)
  local root = cs:pop()
  local chord = int16.imod(cs:pop(), 13)
  if chord < 0 then chord = 13 + chord end
  local component = int16.imod(cs:pop(), 4)
  if component < 0 then component = 4 + component end
  push_transposed(cs, root, T.table_n_c[chord][component])
end)

impl('N.CS', function(_ss, _es, cs)
  local root = cs:pop()
  local scale = int16.imod(cs:pop(), 9)
  if scale < 0 then scale = 9 + scale end
  local scl_deg = int16.imod(cs:pop() - 1, 7)
  if scl_deg < 0 then scl_deg = 7 + scl_deg end
  local scl_trans = T.table_n_s[scale][scl_deg]
  local ch_deg = int16.imod(cs:pop(), 4)
  if ch_deg < 0 then ch_deg = 4 + ch_deg end
  local ch_trans = T.table_n_c[T.table_n_cs[scale][scl_deg]][ch_deg]
  push_transposed(cs, root, scl_trans + ch_trans)
end)

-- user-defined bitmask scales ------------------------------------------------
-- N.B reads a degree from scale 0; setting it takes (bits, root). a
-- non-positive `bits` selects one of the built-in presets by negated index.

local function decode_scale_bits(scale_bits)
  if scale_bits < 1 then
    if scale_bits > -NB_SCALE_PRESETS then
      return helpers.bit_reverse(T.table_n_b[-scale_bits], 12)
    end
    return helpers.bit_reverse(T.table_n_b[0], 12)
  end
  return scale_bits & 0xfff
end

impl('N.B',
  function(ss, _es, cs)
    local degree = cs:pop()
    cs:push(get_degree_in_bitmask_scale(ss.variables.n_scale_bits[0],
      ss.variables.n_scale_root[0], degree))
  end,
  function(ss, _es, cs)
    ss.variables.n_scale_root[0] = cs:pop()
    ss.variables.n_scale_bits[0] = decode_scale_bits(cs:pop())
  end)

impl('N.BX',
  function(ss, _es, cs)
    local scale_nb = cs:pop()
    local degree = cs:pop()
    if scale_nb < 0 then scale_nb = 0 end
    if scale_nb > NB_NBX_SCALES - 1 then scale_nb = NB_NBX_SCALES - 1 end
    cs:push(get_degree_in_bitmask_scale(ss.variables.n_scale_bits[scale_nb],
      ss.variables.n_scale_root[scale_nb], degree))
  end,
  function(ss, _es, cs)
    local scale_nb = int16.imod(cs:pop(), 8)
    ss.variables.n_scale_root[scale_nb] = cs:pop()
    local bits = decode_scale_bits(cs:pop())
    if scale_nb < 0 then scale_nb = 0 end
    if scale_nb > NB_NBX_SCALES - 1 then scale_nb = NB_NBX_SCALES - 1 end
    ss.variables.n_scale_bits[scale_nb] = bits
  end)
