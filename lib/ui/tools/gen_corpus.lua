-- gen_corpus.lua
--
-- Assembles test/fixtures/parse_corpus.txt, the set of source lines that the
-- lua parser is diffed against the C oracle over.
--
-- Four sources, because each covers something the others miss:
--   1. teletype/tests/parser_tests.c   -- upstream's own 141-line corpus
--   2. teletype/presets/tt*.txt        -- real scenes, real idiom
--   3. every op and mod name           -- proves all 958 names lex correctly
--   4. hand-written edge cases         -- the error paths and number formats
--
-- usage: lua5.4 lib/tools/gen_corpus.lua

local TT = '../teletype'
local OUT = 'test/fixtures/parse_corpus.txt'

local manifest = dofile('lib/ops/manifest.lua')

local lines, seen = {}, {}

local function add(s)
  if not s or s == '' then return end
  if seen[s] then return end
  -- the corpus is one-line-per-record TSV downstream; a tab would break it
  if s:find('\t') then return end
  seen[s] = true
  lines[#lines + 1] = s
end

-- 1. upstream corpus ---------------------------------------------------------
do
  local f = assert(io.open(TT .. '/tests/parser_tests.c'))
  local src = f:read('a')
  f:close()
  -- the corpus array holds plain "..." literals, one per entry
  -- the array closes with `" };` on the last entry's line, not on its own
  local body = src:match('char corpus%b[]%b[] = {(.-)};')
  assert(body, 'could not find corpus array')
  for str in body:gmatch('"([^"]*)"') do add(str) end
end

-- 2. real scenes -------------------------------------------------------------
do
  local p = io.popen('ls ' .. TT .. '/presets/*.txt 2>/dev/null')
  for path in p:lines() do
    local f = io.open(path)
    if f then
      local in_script = false
      for line in f:lines() do
        line = line:gsub('\r$', '')
        if line:match('^#') then
          -- #1..#8/#M/#I are script sections; #P and #G are data
          in_script = line:match('^#[1-8MI]$') ~= nil
        elseif in_script then
          add((line:gsub('%s+$', '')))
        end
      end
      f:close()
    end
  end
  p:close()
end

-- 3. every op and mod name ---------------------------------------------------
-- bare names exercise the lexer; they often fail validation, which is fine --
-- the oracle records that too and we diff against it.
for _, o in ipairs(manifest.ops) do add(o[1]) end
for _, m in ipairs(manifest.mods) do add(m[1] .. ' 1: A 1') end

-- ops applied with plausible argument counts, so validate() sees real shapes
for _, o in ipairs(manifest.ops) do
  local args = {}
  for i = 1, o[2] do args[i] = tostring(i) end
  add(o[1] .. (#args > 0 and (' ' .. table.concat(args, ' ')) or ''))
  -- and one extra argument, to exercise the set path where one exists
  args[#args + 1] = '1'
  add(o[1] .. ' ' .. table.concat(args, ' '))
end

-- 4. edge cases --------------------------------------------------------------
local edge = {
  -- number formats, including the clamp and truncation paths
  '0', '-0', '1', '-1', '32767', '32768', '-32768', '-32769',
  '99999', '-99999', '000123',
  'X0', 'XF', 'XFF', 'XFFF', 'XFFFF', 'XFFFFF', 'X99999', 'X7FFF', 'X8000',
  'B0', 'B1', 'B01', 'B10', 'B1111111111111111', 'B11111111111111111',
  'R0', 'R1', 'R01', 'R10', 'R1000', 'R0001', 'R1111111111111111',
  -- the [B|R] character-class quirk: '|' is in the class too
  '|101', '|0',
  -- separators
  'A 1', 'A 1; B 2', 'A 1; B 2; C 3',
  'IF 1: A 1', 'IF 1: A 1; B 2',
  'ELSE: A 1', 'ELIF 1: A 1',
  'L 1 4: A I', 'W LT X 4: X ADD X 1',
  'EVERY 4: TR.P A', 'SKIP 4: TR.P A', 'OTHER: TR.P B', 'PROB 50: TR.P A',
  'DEL 100: TR.P A', 'DEL.X 4 100: TR.P A', 'DEL.B 100 B1011: TR.P A',
  'S: TR.P A', 'P.MAP: MUL I 2', 'PN.MAP 1: MUL I 2',
  -- error paths
  'IF 1:', 'A:', 'A;', ':', ';', ': ', '; ',
  'IF 1: A 1: B 2',        -- two PRE separators
  'A 1: B 2',              -- PRE separator with no MOD
  'IF 1; A 1',             -- SUB separator where a PRE belongs
  'A IF 1: B 2',           -- MOD not in first position
  'ADD 1',                 -- not enough params
  'ADD 1 2 3',             -- too many
  'ADD ADD 1 2 3',
  'TR.P',                  -- missing param
  'CV 1 TR.P A',           -- non-returning op used as an argument
  'BOGUS', 'bogus', 'CV.NOPE', 'P..N', '..', '...',
  -- length: 15 words is the effective maximum, 16 errors
  'ADD 1 ADD 1 ADD 1 ADD 1 ADD 1 ADD 1 1',
  'ADD 1 ADD 1 ADD 1 ADD 1 ADD 1 ADD 1 ADD 1 1',
  'ADD 1 ADD 1 ADD 1 ADD 1 ADD 1 ADD 1 ADD 1 ADD 1 1',
  -- whitespace handling
  '  A  1  ', '\tA\t1', 'A  1',
  -- a long token, over the 32-char truncation limit
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  -- symbol ops, which the lexer treats like any other name
  'X + 1 1', 'X - 5 2', 'X * 2 3', 'X / 9 3', 'X % 9 4',
  'X == 1 1', 'X != 1 2', 'X < 1 2', 'X > 2 1', 'X <= 1 1', 'X >= 1 1',
  'X && 1 1', 'X || 0 1', 'X ! 0', 'X ~ 1', 'X ^ 3 1', 'X | 1 2', 'X & 3 1',
  'X << 1 2', 'X >> 4 1', 'X <<< 1 2', 'X >>> 4 1',
  'X >< 5 0 10', 'X <> 5 0 10', 'X >=< 5 0 10', 'X <=> 5 0 10',
  'X ? 1 2 3',
}
for _, s in ipairs(edge) do add(s) end

local f = assert(io.open(OUT, 'w'))
for _, line in ipairs(lines) do f:write(line, '\n') end
f:close()

print(('wrote %s: %d lines'):format(OUT, #lines))
