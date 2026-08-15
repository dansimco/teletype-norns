-- gen_process_corpus.lua
--
-- Builds test/fixtures/process_corpus.txt: lines executed against a single
-- persistent scene by both the C oracle and the lua port, so results *and*
-- accumulated state are compared.
--
-- Randomness is always seeded explicitly first. The C's un-seeded generators
-- come from stdlib rand(), which the lua port has no way to reproduce; once
-- SEED is set both sides run the same MWC sequence.
--
-- usage: lua5.4 lib/tools/gen_process_corpus.lua

local OUT = 'test/fixtures/process_corpus.txt'

local lines = {}
local function add(...)
  for _, s in ipairs({ ... }) do lines[#lines + 1] = s end
end

local function section(title)
  add('# ---- ' .. title)
end

-- interesting operand values: identity, boundaries, signs, overflow edges
local VALUES = { 0, 1, -1, 2, 3, 7, 10, 12, 100, -100, 1000, 16383, 32767, -32768 }

-- arithmetic and comparison --------------------------------------------------
section('binary arithmetic')
local BINARY = {
  'ADD', 'SUB', 'MUL', 'DIV', 'MOD', 'MIN', 'MAX', 'AVG',
  'EQ', 'NE', 'LT', 'GT', 'LTE', 'GTE',
  'AND', 'OR', '|', '&', '^',
  'RSH', 'LSH', 'RROT', 'LROT',
  'BSET', 'BGET', 'BCLR', 'BTOG',
  'QT',
}
for _, op in ipairs(BINARY) do
  for _, a in ipairs(VALUES) do
    for _, b in ipairs({ 0, 1, -1, 2, 3, 7, 12, 100, -100, 16383, 32767 }) do
      add(('%s %d %d'):format(op, a, b))
    end
  end
end

section('unary')
-- HZ reads table_n[-1] in the C for inputs below -table_n[127], an
-- out-of-bounds read we deliberately do not reproduce (see
-- docs/differences.md), so its operands are kept above that threshold.
local HZ_MIN = -17340
-- EXP clamps to -16383 and then shifts right by 6, giving index 256 -- one
-- past the end of table_exp[256]. same story as HZ; operands stay above it.
local EXP_MIN = -16320
for _, op in ipairs({ 'NZ', 'EZ', 'ABS', 'SGN', '~', 'BREV', 'EXP', 'N', 'VN',
                      'V', 'VV', 'HZ', 'BPM' }) do
  for _, a in ipairs(VALUES) do
    -- VV negates its operand as an int16, so -32768 stays negative, escapes
    -- the >1000 clamp and indexes table_v/table_vv at -327/-68.
    local vv_ub = (op == 'VV' and a == -32768)
    if not (op == 'HZ' and a < HZ_MIN) and not (op == 'EXP' and a < EXP_MIN)
        and not vv_ub then
      add(('%s %d'):format(op, a))
    end
  end
  -- the pitch ops care about the full note range
  for a = -130, 130, 7 do add(('%s %d'):format(op, a)) end
end

section('ternary and beyond')
for _, op in ipairs({ 'LIM', 'WRAP', 'INR', 'OUTR', 'INRI', 'OUTRI', '?',
                      'AND3', 'OR3', 'SCALE0' }) do
  for _, a in ipairs({ 0, 1, -1, 5, 10, -10, 100 }) do
    for _, b in ipairs({ 0, 1, 5, 10, -5 }) do
      for _, c in ipairs({ 0, 3, 7, -7 }) do
        add(('%s %d %d %d'):format(op, a, b, c))
      end
    end
  end
end

for _, a in ipairs({ 0, 1, 10, 100 }) do
  for _, b in ipairs({ 0, 1, 10, 16383 }) do
    add(('AND4 %d %d %d %d'):format(a, b, a, b))
    add(('OR4 %d %d %d %d'):format(a, b, a, b))
    add(('SCALE 0 %d 0 %d %d'):format(a, b, a))
    add(('SCALE %d %d %d %d %d'):format(a, b, 0, 100, b))
  end
end

section('just intonation')
for n = 0, 16 do
  for d = 1, 16 do
    add(('JI %d %d'):format(n, d))
  end
end

section('quantisation and scales')
for _, v in ipairs({ 0, 819, 1638, 2000, 3277, -1638, -800, 16383 }) do
  add(('QT.B %d'):format(v))
  for s = 0, 8 do
    add(('QT.S %d 0 %d'):format(v, s))
    add(('QT.CS %d 0 %d 1 3'):format(v, s))
  end
  for x = 0, 3 do
    add(('QT.BX %d %d'):format(x, v))
  end
end
for r = 0, 12, 3 do
  for s = 0, 8 do
    for d = 1, 7 do
      add(('N.S %d %d %d'):format(r, s, d))
      add(('N.CS %d %d %d 0'):format(r, s, d))
    end
  end
  for c = 0, 12 do
    for comp = 0, 3 do
      add(('N.C %d %d %d'):format(r, c, comp))
    end
  end
end

section('bitmask scales are stateful')
-- argument order is (root, bits) -- the first pop is the leftmost argument,
-- and the C assigns that one to n_scale_root. a root outside 0..127 sends the
-- C's unclamped table_n lookup out of bounds, so roots stay in range here.
for _, bits in ipairs({ 0, 1, 2741, -1, -5, 4095 }) do
  for _, root in ipairs({ 0, 3, 12 }) do
    add(('N.B %d %d'):format(root, bits))
    for d = -3, 8 do add(('N.B %d'):format(d)) end
    add(('N.BX 2 %d %d'):format(root, bits))
    for d = -3, 8 do add(('N.BX 2 %d'):format(d)) end
  end
end

-- variables ------------------------------------------------------------------
section('simple variables')
for _, v in ipairs({ 'A', 'B', 'C', 'D', 'X', 'Y', 'Z', 'T' }) do
  add(v, ('%s 5'):format(v), v, ('%s -32768'):format(v), v,
      ('%s ADD %s 1'):format(v, v), v)
end

section('O auto-increments')
add('O.MIN 0', 'O.MAX 5', 'O.INC 1', 'O.WRAP 1', 'O 0')
for _ = 1, 10 do add('O') end
add('O.INC 2', 'O 0')
for _ = 1, 8 do add('O') end
add('O.WRAP 0', 'O 0')
for _ = 1, 8 do add('O') end

section('FLIP toggles on read')
add('FLIP 0')
for _ = 1, 5 do add('FLIP') end
add('FLIP 1')
for _ = 1, 5 do add('FLIP') end

section('DRUNK walks')
add('SEED 12345', 'DRUNK.MIN 0', 'DRUNK.MAX 10', 'DRUNK.WRAP 0', 'DRUNK 5')
for _ = 1, 20 do add('DRUNK') end
add('DRUNK.WRAP 1', 'DRUNK 5')
for _ = 1, 20 do add('DRUNK') end

-- randomness -----------------------------------------------------------------
section('seeded randomness is reproducible')
for _, seed in ipairs({ 0, 1, 42, 12345 }) do
  add(('SEED %d'):format(seed))
  for _ = 1, 12 do add('RAND 100') end
  for _ = 1, 12 do add('RRAND -50 50') end
  for _ = 1, 12 do add('TOSS') end
  add(('RAND.SEED %d'):format(seed))
  for _ = 1, 8 do add('RAND 10') end
  add(('TOSS.SEED %d'):format(seed))
  for _ = 1, 8 do add('TOSS') end
  add('R.MIN 10', 'R.MAX 20')
  for _ = 1, 8 do add('R') end
  add('R 7')
  for _ = 1, 4 do add('R') end
  add('R.MIN', 'R.MAX', 'SEED', 'RAND.SEED', 'TOSS.SEED', 'PROB.SEED',
      'DRUNK.SEED', 'P.SEED')
end
add('SEED 99', 'RAND 0', 'RAND -10', 'RAND 32767', 'RRAND 5 5', 'RRAND 5 -5')

-- expressions ----------------------------------------------------------------
section('nested expressions and sub-commands')
add(
  'X ADD 1 MUL 2 3',
  'X SUB MUL 3 4 DIV 10 2',
  'A 1; B 2; C 3',
  'X 0; X ADD X 1; X ADD X 1',
  'Y ADD X MUL 2 SUB 10 3',
  'X + 1 1', 'X - 5 2', 'X * 2 3', 'X / 9 3', 'X % 9 4',
  'X == 1 1', 'X != 1 2', 'X < 1 2', 'X > 2 1',
  'X && 1 1', 'X || 0 1', 'X ! 0', 'X ~ 1',
  'X << 1 2', 'X >> 4 1', 'X <<< 1 2', 'X >>> 4 1',
  'X >< 5 0 10', 'X <> 5 0 10', 'X >=< 5 0 10', 'X <=> 5 0 10',
  'X ? 1 2 3', 'X ? 0 2 3',
  'X SCL 0 10 0 100 5', 'X SCL0 10 100 5',
  'X WRP 12 0 10', 'X LIM 12 0 10'
)

-- control flow -----------------------------------------------------------------
-- these need a real script context: EVERY/SKIP count per (script, line), and
-- SCRIPT/$F/$L only run scripts that have lines installed.

section('IF / ELIF / ELSE chains')
add('!clear 0')
add('!script 0 0 IF EQ X 1: Y 10')
add('!script 0 1 ELIF EQ X 2: Y 20')
add('!script 0 2 ELIF EQ X 3: Y 30')
add('!script 0 3 ELSE: Y 99')
for _, x in ipairs({ 0, 1, 2, 3, 4 }) do
  add(('X %d'):format(x), 'Y 0', '!run 0', 'Y')
end

section('L loops')
add('!clear 1')
add('!script 1 0 L 1 5: Z ADD Z I')
add('Z 0', '!run 1', 'Z', 'I')
add('!clear 1')
add('!script 1 0 L 5 1: Z ADD Z I')
add('Z 0', '!run 1', 'Z', 'I')
add('!clear 1')
-- the body advancing I is the documented way to step a loop by more than one
add('!script 1 0 L 1 10: I ADD I 1; Z ADD Z 1')
add('Z 0', '!run 1', 'Z')
add('!clear 1')
add('!script 1 0 L 1 10: IF EQ I 4: BREAK')
add('!script 1 1 Z I')
add('Z 0', '!run 1', 'Z')

section('W while loop')
add('!clear 2')
add('!script 2 0 W LT X 10: X ADD X 1')
add('X 0', '!run 2', 'X')
add('X 20', '!run 2', 'X')

section('EVERY / SKIP / OTHER')
add('!clear 3')
add('!script 3 0 EVERY 3: A ADD A 1')
add('!script 3 1 SKIP 3: B ADD B 1')
add('!script 3 2 OTHER: C ADD C 1')
add('A 0', 'B 0', 'C 0')
for _ = 1, 12 do add('!run 3') end
add('A', 'B', 'C')
add('SYNC 0')
for _ = 1, 6 do add('!run 3') end
add('A', 'B', 'C')

section('PROB is seeded')
add('SEED 777')
add('!clear 4')
add('!script 4 0 PROB 50: D ADD D 1')
add('D 0')
for _ = 1, 40 do add('!run 4') end
add('D')

section('SCRIPT calls and recursion guard')
add('!clear 5', '!clear 6')
add('!script 5 0 X ADD X 1')
add('!script 6 0 SCRIPT 6')
add('X 0', '!run 5', 'X')
add('SCRIPT 6', 'X')
add('!clear 6')
add('!script 6 0 SCRIPT 6')  -- infinite recursion, stopped by EXEC_DEPTH
add('!run 6', 'X')
add('SCRIPT', 'SCRIPT.POL 1', 'SCRIPT.POL 1 3', 'SCRIPT.POL 1',
    'SCRIPT.POL 0 2', 'SCRIPT.POL 4', 'SCRIPT.POL 9', 'SCRIPT.POL 0')

section('functions: $F / $L / $S with I1, I2 and FR')
add('!clear 7')
add('!script 7 0 FR ADD I1 I2')
add('$F 8', '$F1 8 5', '$F2 8 5 7')
add('$L 8 1', '$L1 8 1 5', '$L2 8 1 5 7')
add('!clear 7')
add('!script 7 0 FR MUL I1 2')
add('!script 7 1 FR ADD I1 100')
add('$F1 8 21', '$L1 8 1 21', '$L1 8 2 21')
add('$F 0', '$F 11', '$F 99', '$L 8 9', 'I1', 'I2', 'FR', 'FR 5', 'FR')

section('BREAK and KILL')
add('!clear 0')
add('!script 0 0 X 1')
add('!script 0 1 BREAK')
add('!script 0 2 X 2')
add('X 0', '!run 0', 'X')

-- patterns ---------------------------------------------------------------------
section('pattern basics')
add('P.N 0', 'P.L 0')
for i = 0, 7 do add(('P.PUSH %d'):format(i * 10)) end
add('P.L', 'P 0', 'P 3', 'P 7', 'P -1', 'P -8', 'P -9', 'P 63', 'P 64', 'P 100')
add('P 2 55', 'P 2', 'P.HERE', 'P.I', 'P.I 3', 'P.I', 'P.HERE', 'P.HERE 77', 'P 3')

section('playhead movement')
add('P.START 0', 'P.END 5', 'P.WRAP 1', 'P.I 0')
for _ = 1, 12 do add('P.NEXT') end
for _ = 1, 12 do add('P.PREV') end
add('P.WRAP 0', 'P.I 0')
for _ = 1, 10 do add('P.NEXT') end
add('P.START 2', 'P.END 4', 'P.I 0')
for _ = 1, 10 do add('P.NEXT') end
add('P.I', 'P.START', 'P.END', 'P.WRAP', 'P.L')

section('insertion and removal')
add('P.N 1', 'P.L 0')
for i = 1, 6 do add(('P.PUSH %d'):format(i)) end
add('P.INS 2 99', 'P.L', 'P 0', 'P 1', 'P 2', 'P 3')
add('P.RM 0', 'P.L', 'P 0')
add('P.POP', 'P.L')
add('P.RM 100', 'P.INS 100 5', 'P.L')
add('P.L 0', 'P.POP', 'P.RM 0')

section('reordering is seeded')
add('SEED 4242', 'P.N 2', 'P.L 0')
for i = 1, 8 do add(('P.PUSH %d'):format(i)) end
add('P.START 0', 'P.END 7')
add('P.REV')
for i = 0, 7 do add(('P %d'):format(i)) end
add('P.ROT 3')
for i = 0, 7 do add(('P %d'):format(i)) end
add('P.ROT -2')
for i = 0, 7 do add(('P %d'):format(i)) end
add('P.SHUF')
for i = 0, 7 do add(('P %d'):format(i)) end
add('P.MIN', 'P.MAX')
for _ = 1, 8 do add('P.RND') end

section('per-step arithmetic')
add('P.N 3', 'P.L 0')
for i = 1, 6 do add(('P.PUSH %d'):format(i)) end
add('P.+ 0 10', 'P 0', 'P.- 1 10', 'P 1')
add('P.+W 2 100 0 10', 'P 2', 'P.-W 3 100 0 10', 'P 3')
add('PN.+ 3 4 5', 'PN 3 4', 'PN.- 3 5 5', 'PN 3 5')

section('explicit-pattern forms')
-- give every pattern a non-zero length first: P.PREV on an empty pattern sets
-- the index to -1, and the C then reads val[-1], which aliases the adjacent
-- `end` field of the struct. see docs/differences.md.
for n = 0, 3 do
  add(('PN.L %d 8'):format(n))
end
for n = 0, 3 do
  add(('PN.L %d'):format(n), ('PN.I %d'):format(n), ('PN.START %d'):format(n),
      ('PN.END %d'):format(n), ('PN.WRAP %d'):format(n),
      ('PN.HERE %d'):format(n), ('PN %d 0'):format(n),
      ('PN.NEXT %d'):format(n), ('PN.PREV %d'):format(n),
      ('PN.MIN %d'):format(n), ('PN.MAX %d'):format(n))
end
add('P.N 5', 'P.N', 'P.N -3', 'P.N', 'P.N 2', 'P.N')

section('P.MAP writes results back')
add('P.N 0', 'P.L 0')
for i = 1, 6 do add(('P.PUSH %d'):format(i)) end
add('P.START 0', 'P.END 5')
add('!clear 0')
add('!script 0 0 P.MAP: MUL I 2')
add('!run 0')
for i = 0, 5 do add(('P %d'):format(i)) end
add('!clear 0')
add('!script 0 0 PN.MAP 1: ADD I 100')
add('!run 0')
for i = 0, 5 do add(('PN 1 %d'):format(i)) end

-- hardware --------------------------------------------------------------------
section('CV')
for n = 1, 4 do
  add(('CV %d'):format(n), ('CV %d V 5'):format(n), ('CV %d'):format(n),
      ('CV %d 16383'):format(n), ('CV %d'):format(n),
      ('CV %d -100'):format(n), ('CV %d'):format(n),
      ('CV %d 99999'):format(n), ('CV %d'):format(n),
      ('CV.SET %d V 2'):format(n), ('CV %d'):format(n),
      ('CV.SLEW %d'):format(n), ('CV.SLEW %d 500'):format(n),
      ('CV.SLEW %d'):format(n), ('CV.SLEW %d 0'):format(n),
      ('CV.SLEW %d'):format(n), ('CV.SLEW %d -5'):format(n),
      ('CV.OFF %d'):format(n), ('CV.OFF %d 100'):format(n),
      ('CV.OFF %d'):format(n), ('CV.OFF %d -100'):format(n),
      ('CV.GET %d'):format(n))
end

section('TR')
for n = 1, 4 do
  add(('TR %d'):format(n), ('TR %d 1'):format(n), ('TR %d'):format(n),
      ('TR %d 0'):format(n), ('TR %d 5'):format(n), ('TR %d'):format(n),
      ('TR.TOG %d'):format(n), ('TR %d'):format(n),
      ('TR.TOG %d'):format(n), ('TR %d'):format(n),
      ('TR.TIME %d'):format(n), ('TR.TIME %d 50'):format(n),
      ('TR.TIME %d'):format(n), ('TR.TIME %d -5'):format(n),
      ('TR.TIME %d'):format(n),
      ('TR.POL %d'):format(n), ('TR.POL %d 0'):format(n),
      ('TR.POL %d'):format(n), ('TR.PULSE %d'):format(n),
      ('TR %d'):format(n),
      ('TR.POL %d 1'):format(n), ('TR.P %d'):format(n), ('TR %d'):format(n),
      ('TR.TIME %d 0'):format(n), ('TR.PULSE %d'):format(n))
end

section('CV/TR indices route to ansible over i2c')
-- 1..4 are local, 5..20 go to an Ansible (four per device, address stride 2),
-- anything else is a no-op returning 0
for _, n in ipairs({ 0, -1, 5, 6, 7, 8, 9, 12, 16, 19, 20, 21, 40 }) do
  add(('CV %d'):format(n), ('CV %d 8192'):format(n),
      ('CV.SLEW %d'):format(n), ('CV.SLEW %d 250'):format(n),
      ('CV.OFF %d'):format(n), ('CV.OFF %d 64'):format(n),
      ('CV.SET %d 4096'):format(n),
      ('TR %d'):format(n), ('TR %d 1'):format(n),
      ('TR.TOG %d'):format(n), ('TR.PULSE %d'):format(n),
      ('TR.TIME %d'):format(n), ('TR.TIME %d 30'):format(n),
      ('TR.POL %d'):format(n), ('TR.POL %d 0'):format(n),
      ('STATE %d'):format(n))
end

section('IN / PARAM scaling')
add('IN', 'PARAM', 'PRM')
add('IN.SCALE 0 100', 'IN', 'PARAM.SCALE 0 100', 'PARAM')
add('IN.SCALE -100 100', 'IN', 'PARAM.SCALE -1000 1000', 'PARAM')
add('IN.CAL.MIN', 'IN.CAL.MAX', 'IN', 'IN.CAL.RESET', 'IN')
add('PARAM.CAL.MIN', 'PARAM.CAL.MAX', 'PARAM', 'PARAM.CAL.RESET', 'PARAM')
add('IN.SCALE 0 16383', 'PARAM.SCALE 0 16383')

section('mutes and calibration')
for n = 0, 9 do
  add(('MUTE %d'):format(n), ('MUTE %d 1'):format(n), ('MUTE %d'):format(n),
      ('MUTE %d 0'):format(n), ('MUTE %d'):format(n))
end
add('CV.CAL 1 100 300', 'CV.CAL.RESET 1', 'CV.CAL 0 100 300',
    'CV.CAL 5 100 300', 'CV.CAL.RESET 9')

section('dashboard and live submodes')
add('LIVE.OFF', 'LIVE.O', 'LIVE.VARS', 'LIVE.V', 'LIVE.GRID', 'LIVE.G',
    'LIVE.DASH 1', 'LIVE.D 2', 'DEVICE.FLIP')
add('PRINT 1', 'PRINT 1 42', 'PRT 2', 'PRT 2 7')

-- timing --------------------------------------------------------------------
section('metronome')
add('M', 'M 500', 'M', 'M 10', 'M', 'M! 10', 'M', 'M! 1', 'M', 'M 1000',
    'M.ACT', 'M.ACT 0', 'M.ACT', 'M.ACT 1', 'M.ACT', 'M.RESET')

section('command stack')
add('S.CLR', 'S.L')
add('!clear 0')
add('!script 0 0 S: X ADD X 1')
add('X 0', '!run 0', '!run 0', '!run 0', 'S.L', 'X')
add('S.ALL', 'X', 'S.L')
add('!run 0', '!run 0', 'S.L', 'S.POP', 'X', 'S.L', 'S.POP', 'X', 'S.L')
add('S.POP', 'S.L')
-- overflow: the stack holds 16, further pushes are dropped
add('!clear 1')
add('!script 1 0 S: Y ADD Y 1')
add('Y 0')
for _ = 1, 20 do add('!run 1') end
add('S.L', 'S.ALL', 'Y', 'S.L')

section('delays')
add('DEL.CLR')
add('!clear 2')
add('!script 2 0 DEL 100: Z ADD Z 1')
add('Z 0', '!run 2')
add('!tick 10', '!tick 10', '!tick 10', 'Z')
for _ = 1, 8 do add('!tick 10') end
add('Z')
add('!tick 10', 'Z')

section('DEL.X spaces delays evenly')
add('DEL.CLR', '!clear 3')
add('!script 3 0 DEL.X 4 50: Z ADD Z 1')
add('Z 0', '!run 3')
for _ = 1, 25 do add('!tick 10') end
add('Z')

section('DEL.R fires the first immediately')
add('DEL.CLR', '!clear 4')
add('!script 4 0 DEL.R 3 50: Z ADD Z 1')
add('Z 0', '!run 4', '!tick 10', 'Z')
for _ = 1, 20 do add('!tick 10') end
add('Z')

section('DEL.G scales the gap geometrically')
add('DEL.CLR', '!clear 5')
add('!script 5 0 DEL.G 4 20 3 2: Z ADD Z 1')
add('Z 0', '!run 5')
for _ = 1, 30 do add('!tick 10') end
add('Z')

section('DEL.B places delays on a bitmask')
add('DEL.CLR', '!clear 6')
add('!script 6 0 DEL.B 20 B1011: Z ADD Z 1')
add('Z 0', '!run 6')
for _ = 1, 12 do add('!tick 10') end
add('Z')
add('DEL.CLR', 'Z')

section('delayed commands keep their origin context')
add('DEL.CLR', '!clear 7')
add('!script 7 0 L 1 3: DEL MUL I 20: Y ADD Y I')
add('Y 0', '!run 7')
for _ = 1, 10 do add('!tick 10') end
add('Y')
add('DEL.CLR')

-- queue ---------------------------------------------------------------------
-- Q.RND is excluded: the C uses stdlib rand(), which is not reproducible and
-- is not even affected by SEED on hardware. See docs/differences.md.
section('queue basics')
add('Q.CLR', 'Q.N', 'Q.GRW')
for i = 1, 8 do add(('Q %d'):format(i * 3)) end
add('Q', 'Q.N 5', 'Q', 'Q.N', 'Q.I 0', 'Q.I 1', 'Q.I 7', 'Q.I 70', 'Q.I -5')
add('Q.I 2 99', 'Q.I 2', 'Q.SUM', 'Q.AVG', 'Q.MIN', 'Q.MAX')

section('growing queue')
add('Q.CLR', 'Q.GRW 1', 'Q.GRW', 'Q.N')
for i = 1, 6 do add(('Q %d'):format(i)) end
add('Q.N')
for _ = 1, 4 do add('Q') end
add('Q.N', 'Q.GRW 0', 'Q.GRW', 'Q.N')

section('queue reordering')
add('Q.CLR', 'Q.N 8')
for i = 1, 8 do add(('Q %d'):format(9 - i)) end
add('Q.SRT')
for i = 0, 7 do add(('Q.I %d'):format(i)) end
add('Q.REV')
for i = 0, 7 do add(('Q.I %d'):format(i)) end
add('Q.SH 2')
for i = 0, 7 do add(('Q.I %d'):format(i)) end
add('Q.SH -3')
for i = 0, 7 do add(('Q.I %d'):format(i)) end
add('Q.SRT 4')
for i = 0, 7 do add(('Q.I %d'):format(i)) end
add('Q.SRT -4')
for i = 0, 7 do add(('Q.I %d'):format(i)) end
add('Q.SRT 0')
for i = 0, 7 do add(('Q.I %d'):format(i)) end

section('queue arithmetic')
add('Q.CLR', 'Q.N 6')
for i = 1, 6 do add(('Q %d'):format(i * 100)) end
add('Q.ADD 5')
for i = 0, 5 do add(('Q.I %d'):format(i)) end
add('Q.SUB 3')
for i = 0, 5 do add(('Q.I %d'):format(i)) end
add('Q.MUL 2')
for i = 0, 5 do add(('Q.I %d'):format(i)) end
add('Q.DIV 3')
for i = 0, 5 do add(('Q.I %d'):format(i)) end
add('Q.MOD 7')
for i = 0, 5 do add(('Q.I %d'):format(i)) end
add('Q.DIV 0', 'Q.MOD 0')
add('Q.ADD 0 100', 'Q.I 0', 'Q.SUB 1 10', 'Q.I 1')
add('Q.MUL 2 3', 'Q.I 2', 'Q.DIV 3 2', 'Q.I 3', 'Q.MOD 4 5', 'Q.I 4')
add('Q.ADD 99 1', 'Q.ADD -5 1', 'Q.I 0')
add('Q.MIN 50', 'Q.MAX 200')
for i = 0, 5 do add(('Q.I %d'):format(i)) end
add('Q.AVG 42')
for i = 0, 5 do add(('Q.I %d'):format(i)) end

section('queue and pattern interchange')
add('Q.CLR', 'Q.N 8')
for i = 1, 8 do add(('Q %d'):format(i * 11)) end
add('P.N 0', 'Q.2P')
for i = 0, 7 do add(('P %d'):format(i)) end
add('Q.2P 2')
for i = 0, 7 do add(('PN 2 %d'):format(i)) end
add('PN 3 0 77', 'PN 3 1 88', 'Q.P2 3', 'Q.I 0', 'Q.I 1')
add('P.N 0', 'Q.P2', 'Q.I 0', 'Q.I 1')
add('Q.CLR 5', 'Q.I 0', 'Q.N')

-- rhythm ----------------------------------------------------------------------
section('euclidean and numeric repetitor')
for fill = 0, 16 do
  for len = 1, 16, 3 do
    for step = 0, 15 do add(('ER %d %d %d'):format(fill, len, step)) end
  end
end
add('ER 0 0 0', 'ER 33 33 0', 'ER -1 8 0', 'ER 4 8 -1', 'ER 4 8 40')
for prime = 0, 8 do
  for mask = 0, 3 do
    for step = 0, 15, 5 do
      add(('NR %d %d 3 %d'):format(prime, mask, step))
    end
  end
end
add('NR -1 -1 -1 -1', 'NR 40 9 20 20')

section('drum patterns')
for bank = 0, 4 do
  for _, pattern in ipairs({ 0, 1, 5, 17, 100, 215 }) do
    for step = 0, 15 do add(('DR.P %d %d %d'):format(bank, pattern, step)) end
  end
end
add('DR.P -1 0 0', 'DR.P 5 0 0', 'DR.P 0 216 0', 'DR.P 0 0 -1', 'DR.P 0 0 99')
for bank = 0, 4 do
  for _, len in ipairs({ 8, 16, 32 }) do
    for step = 0, 15 do
      add(('DR.T %d 1 2 %d %d'):format(bank, len, step))
    end
  end
end
add('DR.T 0 0 0 4 0', 'DR.T 9 0 0 8 0', 'DR.T 0 216 0 8 0', 'DR.T 0 0 216 8 0')
for pattern = 0, 19 do
  for step = 0, 15 do add(('DR.V %d %d'):format(pattern, step)) end
end
add('DR.V -1 0', 'DR.V 20 0', 'DR.V 0 -1', 'DR.V 0 99')

-- chaos ------------------------------------------------------------------------
section('chaos generators')
for alg = 0, 3 do
  add(('CHAOS.ALG %d'):format(alg), 'CHAOS.ALG')
  add('CHAOS.R 5000', 'CHAOS 5000')
  for _ = 1, 20 do add('CHAOS') end
  add('CHAOS.R 8000', 'CHAOS 1000')
  for _ = 1, 20 do add('CHAOS') end
  add('CHAOS.R', 'CHAOS.R 0', 'CHAOS 0')
  for _ = 1, 10 do add('CHAOS') end
end
add('CHAOS.ALG -1', 'CHAOS.ALG', 'CHAOS.ALG 99', 'CHAOS.ALG')

-- init -------------------------------------------------------------------------
section('INIT family')
add('CHAOS.ALG 0', 'CHAOS.R 5000', 'CHAOS 5000')
add('X 11', 'Y 22', 'P.N 2', 'P.L 5', 'CV 1 V 3', 'TR 1 1', 'M 400')
add('INIT.CV 1', 'CV 1', 'CV.SLEW 1', 'CV.OFF 1')
add('TR.POL 2 0', 'TR.TIME 2 20', 'INIT.TR 2', 'TR 2', 'TR.POL 2', 'TR.TIME 2')
add('CV 3 V 5', 'CV 4 V 5', 'INIT.CV.ALL', 'CV 3', 'CV 4')
add('TR 3 1', 'TR 4 1', 'INIT.TR.ALL', 'TR 3', 'TR 4')
add('INIT.CV 0', 'INIT.CV 9', 'INIT.TR 0', 'INIT.TR 9')
add('P.N 1', 'P.L 8', 'P 0 42', 'INIT.P 1', 'P.L', 'P 0')
add('P.N 0', 'P.L 4', 'INIT.P.ALL', 'P.L')
add('INIT.P -1', 'INIT.P 4')
add('!clear 0')
add('!script 0 0 X 99')
add('INIT.SCRIPT 1')
add('!run 0', 'X')
add('INIT.SCRIPT.ALL', 'INIT.SCRIPT 0', 'INIT.SCRIPT 11')
add('X 5', 'Y 6', 'INIT.DATA', 'X', 'Y', 'M')
add('INIT.TIME', 'TIME')
add('X 7', 'INIT', 'X', 'M', 'P.N')

-- turtle -----------------------------------------------------------------------
section('turtle position and fence')
add('@X', '@Y', '@DIR', '@SPEED', '@BUMP', '@WRAP', '@BOUNCE', '@SCRIPT', '@SHOW')
add('@F 0 0 3 63', '@FX1', '@FY1', '@FX2', '@FY2')
for _, x in ipairs({ 0, 1, 2, 3, 4, -1, 100 }) do
  add(('@X %d'):format(x), '@X')
end
for _, y in ipairs({ 0, 1, 30, 63, 64, -1, 200 }) do
  add(('@Y %d'):format(y), '@Y')
end
add('@X 1', '@Y 10', '@MOVE 1 1', '@X', '@Y')
add('@MOVE -1 -1', '@X', '@Y')
add('@MOVE 5 100', '@X', '@Y')
add('@MOVE -9 -200', '@X', '@Y')

section('turtle fence edges')
for _, v in ipairs({ 0, 1, 2, 3, 4, 10, -1, 300 }) do
  add(('@FX1 %d'):format(v), '@FX1', '@FX2')
  add(('@FX2 %d'):format(v), '@FX1', '@FX2')
  add(('@FY1 %d'):format(v), '@FY1', '@FY2')
  add(('@FY2 %d'):format(v), '@FY1', '@FY2')
end
add('@F 3 63 0 0', '@FX1', '@FY1', '@FX2', '@FY2')
add('@F 1 10 2 20', '@FX1', '@FY1', '@FX2', '@FY2')

section('turtle stepping in each fence mode')
for _, mode in ipairs({ '@BUMP', '@WRAP', '@BOUNCE' }) do
  add('@F 0 0 3 63', ('%s 1'):format(mode), '@BUMP', '@WRAP', '@BOUNCE')
  add('@X 1', '@Y 10', '@SPEED 100')
  for _, dir in ipairs({ 0, 45, 90, 135, 180, 225, 270, 315 }) do
    add(('@DIR %d'):format(dir), '@DIR')
    for _ = 1, 8 do add('@STEP', '@X', '@Y') end
  end
  -- a tight fence exercises the reflection and wrap paths hard
  add('@F 1 5 2 8', '@X 1', '@Y 5')
  for _, dir in ipairs({ 30, 100, 200, 300 }) do
    add(('@DIR %d'):format(dir))
    for _ = 1, 12 do add('@STEP', '@X', '@Y') end
  end
  add('@SPEED 250', '@DIR 45')
  for _ = 1, 10 do add('@STEP', '@X', '@Y') end
  add('@SPEED 25', '@DIR 200')
  for _ = 1, 10 do add('@STEP', '@X', '@Y') end
end
add('@DIR -90', '@DIR', '@DIR 720', '@DIR', '@DIR 361', '@DIR')
add('@SPEED -100', '@SPEED', '@SPEED 0', '@SPEED')

section('turtle reads and writes pattern data')
add('@F 0 0 3 63', '@BUMP 1', '@X 0', '@Y 0')
add('PN 0 0 111', 'PN 1 5 222')
add('@', '@X 1', '@Y 5', '@', '@ 333', '@', 'PN 1 5')
add('@SCRIPT 3', '@SCRIPT', '@SCRIPT 0', '@SCRIPT', '@SCRIPT 11', '@SCRIPT')
add('@SHOW 1', '@SHOW', '@SHOW 0', '@SHOW')

-- generic i2c ------------------------------------------------------------------
section('IIA address selection')
add('IIA', 'IIA 32', 'IIA', 'IIA 127', 'IIA', 'IIA 128', 'IIA', 'IIA 200',
    'IIA', 'IIA -1', 'IIA', 'IIA 0', 'IIA')

section('i2c send and query')
-- with no address selected nothing goes on the wire
add('IIA 200', 'IIS 5', 'IIS1 5 100', 'IIQ 5', 'IIB 5')
add('IIA 32')
add('IIS 1', 'IIS1 2 300', 'IIS2 3 300 400', 'IIS3 4 1 2 3')
add('IISB1 5 200', 'IISB2 6 200 201', 'IISB3 7 1 2 3')
add('IIQ 8', 'IIQ1 9 100', 'IIQ2 10 1 2', 'IIQ3 11 1 2 3')
add('IIQB1 12 5', 'IIQB2 13 5 6', 'IIQB3 14 5 6 7')
add('IIB 15', 'IIB1 16 100', 'IIB2 17 1 2', 'IIB3 18 1 2 3')
add('IIBB1 19 5', 'IIBB2 20 5 6', 'IIBB3 21 5 6 7')
-- negative and oversized arguments exercise the byte packing
add('IIS1 300 -1', 'IIS1 5 -32768', 'IIS1 5 32767', 'IISB1 5 -1')
add('IIA 5', 'IIS1 1 16383', 'IIA 0', 'IIS1 1 16383')

-- ansible ----------------------------------------------------------------------
section('ansible: kria')
for _, v in ipairs({ 0, 1, 3, 7, 255, 300, -1 }) do
  add(('KR.PRE %d'):format(v), 'KR.PRE')
  add(('KR.PAT %d'):format(v), 'KR.PAT')
  add(('KR.SCALE %d'):format(v), 'KR.SCALE')
  add(('KR.PERIOD %d'):format(v), 'KR.PERIOD')
  add(('KR.PG %d'):format(v), 'KR.PG')
  add(('KR.CUE %d'):format(v), 'KR.CUE')
  add(('KR.TMUTE %d'):format(v), ('KR.CLK %d'):format(v), ('KR.RES %d 1'):format(v))
  add(('KR.MUTE %d 1'):format(v), ('KR.MUTE %d'):format(v))
  add(('KR.DIR %d 1'):format(v), ('KR.DIR %d'):format(v))
  add(('KR.POS %d 1 2'):format(v), ('KR.POS %d 1'):format(v))
  add(('KR.L.ST %d 1 2'):format(v), ('KR.L.ST %d 1'):format(v))
  add(('KR.L.LEN %d 1 2'):format(v), ('KR.L.LEN %d 1'):format(v))
end
for n = 0, 6 do add(('KR.CV %d'):format(n), ('KR.DUR %d'):format(n)) end

section('ansible: meadowphysics, levels, cycles')
for _, v in ipairs({ 0, 1, 7, 255, -1 }) do
  add(('ME.PRE %d'):format(v), 'ME.PRE', ('ME.RES %d'):format(v),
      ('ME.STOP %d'):format(v), ('ME.SCALE %d'):format(v), 'ME.SCALE',
      ('ME.PERIOD %d'):format(v), 'ME.PERIOD')
  add(('LV.PRE %d'):format(v), 'LV.PRE', ('LV.RES %d'):format(v),
      ('LV.POS %d'):format(v), 'LV.POS', ('LV.L.ST %d'):format(v), 'LV.L.ST',
      ('LV.L.LEN %d'):format(v), 'LV.L.LEN', ('LV.L.DIR %d'):format(v), 'LV.L.DIR')
  add(('CY.PRE %d'):format(v), 'CY.PRE', ('CY.RES %d'):format(v),
      ('CY.POS %d 3'):format(v), ('CY.POS %d'):format(v), ('CY.REV %d'):format(v))
end
for n = 0, 6 do add(('ME.CV %d'):format(n), ('LV.CV %d'):format(n), ('CY.CV %d'):format(n)) end

section('ansible: midi and arp modes')
for _, v in ipairs({ 0, 1, 1000, -1000, 16383, -32768 }) do
  add(('MID.SHIFT %d'):format(v), ('MID.SLEW %d'):format(v))
  add(('ARP.STY %d'):format(v), ('ARP.HLD %d'):format(v), ('ARP.RES %d'):format(v))
  add(('ARP.RPT 1 2 %d'):format(v), ('ARP.GT 1 %d'):format(v),
      ('ARP.DIV 1 %d'):format(v), ('ARP.SHIFT 1 %d'):format(v),
      ('ARP.SLEW 1 %d'):format(v), ('ARP.FIL 1 %d'):format(v),
      ('ARP.ROT 1 %d'):format(v), ('ARP.ER 1 2 3 %d'):format(v))
end

section('ansible: grid, arc and app passthrough')
add('ANS.APP', 'ANS.APP 0', 'ANS.APP 1', 'ANS.APP 3', 'ANS.APP 255', 'ANS.APP')
for x = 0, 3 do
  for y = 0, 3 do
    -- ANS.G's *getter* is excluded: it transmits one byte more than it
    -- initialises, so the trailing byte is uninitialised stack.
    add(('ANS.G.LED %d %d'):format(x, y),
        ('ANS.G %d %d 1'):format(x, y), ('ANS.G.P %d %d'):format(x, y))
  end
end
for n = 0, 3 do
  add(('ANS.A.LED %d 5'):format(n), ('ANS.A %d 3'):format(n),
      ('ANS.A %d -3'):format(n))
end

-- midi in ----------------------------------------------------------------------
section('MI.$ script bindings')
for event = 0, 8 do
  for _, script in ipairs({ 0, 1, 5, 10, 11, -1 }) do
    add(('MI.$ %d %d'):format(event, script), ('MI.$ %d'):format(event))
  end
end
add('MI.$ 0 3')
for event = 0, 7 do add(('MI.$ %d'):format(event)) end
add('MI.$ 2 5', 'MI.$ 0', 'MI.$ 1', 'MI.$ 2')

section('MI last-event and queue readers')
add('MI.LE', 'MI.LN', 'MI.LNV', 'MI.LV', 'MI.LVV', 'MI.LO', 'MI.LC', 'MI.LCC',
    'MI.LCCV', 'MI.LCH')
add('MI.NL', 'MI.OL', 'MI.CL')
-- the indexed readers key off I, so drive them from a loop
add('!clear 0')
add('!script 0 0 L 1 3: Z ADD Z MI.N')
add('Z 0', '!run 0', 'Z')
add('!clear 0')
add('!script 0 0 L 0 4: Y ADD Y MI.NCH')
add('Y 0', '!run 0', 'Y')
add('MI.N', 'MI.NV', 'MI.V', 'MI.VV', 'MI.NCH')
add('MI.O', 'MI.OCH', 'MI.C', 'MI.CC', 'MI.CCV', 'MI.CCH')

section('MI clock division')
add('MI.CLKD')
for _, v in ipairs({ 0, 1, 6, 24, 25, -1 }) do
  add(('MI.CLKD %d'):format(v), 'MI.CLKD')
end
add('MI.CLKR')

local f = assert(io.open(OUT, 'w'))
for _, line in ipairs(lines) do f:write(line, '\n') end
f:close()

print(('wrote %s: %d lines'):format(OUT, #lines))
