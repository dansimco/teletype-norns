-- gen_tables.lua
--
-- Turns test/fixtures/tables.tsv (produced by `lib/tools/oracle/oracle tables`)
-- into lib/tables.lua. Transcribing these by hand would be ~850 numbers of
-- opportunity for a typo, and every one of them changes pitch or scaling
-- behaviour in a way that is painful to notice later.
--
-- usage: lua5.4 lib/tools/gen_tables.lua

local IN = 'test/fixtures/tables.tsv'
local OUT = 'lib/tables.lua'

-- flat tables are emitted 0-indexed to match the C source; 2d tables keep
-- their [i][j] shape, also 0-indexed.
local FLAT = {
  table_v = true, table_vv = true, table_hzv = true, table_exp = true,
  table_nr = true, table_n = true, table_n_b = true,
  -- one bit-packed integer per drum pattern row
  table_t_r_e = true, table_dr_bd = true, table_dr_sd = true,
  table_dr_ch = true, table_dr_oh = true,
}

local order, data = {}, {}

for line in io.lines(IN) do
  local name, key, value = line:match('^(%S+)\t(%S+)\t(-?%d+)$')
  if name then
    if not data[name] then
      data[name] = {}
      order[#order + 1] = name
    end
    data[name][#data[name] + 1] = { key = key, value = tonumber(value) }
  end
end

local out = {}
local function emit(s) out[#out + 1] = s end

emit([[
-- tables.lua -- GENERATED, do not edit by hand.
--
-- source: teletype/src/table.c and teletype/libavr32/src/music.c, extracted
-- through lib/tools/oracle. regenerate with:
--   make -C lib/tools/oracle && ./lib/tools/oracle/oracle tables > test/fixtures/tables.tsv
--   lua5.4 lib/tools/gen_tables.lua
--
-- every table is 0-indexed, matching the C arrays the ops index into.

local M = {}
]])

-- wrap a long list of numbers so the file stays readable
local function wrap_numbers(values, indent)
  local lines, cur = {}, indent
  for i, v in ipairs(values) do
    local s = tostring(v)
    if i < #values then s = s .. ',' end
    if #cur + #s + 1 > 78 then
      lines[#lines + 1] = cur
      cur = indent
    end
    cur = cur .. (cur == indent and '' or ' ') .. s
  end
  if cur ~= indent then lines[#lines + 1] = cur end
  return table.concat(lines, '\n')
end

for _, name in ipairs(order) do
  local entries = data[name]
  if FLAT[name] then
    local values = {}
    for _, e in ipairs(entries) do values[#values + 1] = e.value end
    emit(('-- %d entries, index 0..%d'):format(#values, #values - 1))
    emit(('M.%s = {'):format(name))
    -- `[0]=` on the first value keeps the literal 0-indexed without any
    -- post-hoc shuffling; the array part then runs 1..n-1 as normal.
    values[1] = ('[0]=%d'):format(values[1])
    emit(wrap_numbers(values, '  '))
    emit('}')
    emit('')
  else
    -- 2d: keys look like "i,j"
    local rows, rowidx = {}, {}
    for _, e in ipairs(entries) do
      local i, j = e.key:match('^(%d+),(%d+)$')
      i, j = tonumber(i), tonumber(j)
      if not rows[i] then rows[i] = {}; rowidx[#rowidx + 1] = i end
      rows[i][j] = e.value
    end
    table.sort(rowidx)
    emit(('M.%s = {}'):format(name))
    for _, i in ipairs(rowidx) do
      local row, j = {}, 0
      while rows[i][j] ~= nil do row[#row + 1] = rows[i][j]; j = j + 1 end
      local parts = {}
      for k, v in ipairs(row) do parts[k] = ('[%d]=%d'):format(k - 1, v) end
      emit(('M.%s[%d] = { %s }'):format(name, i, table.concat(parts, ', ')))
    end
    emit('')
  end
end

emit('return M')

local f = assert(io.open(OUT, 'w'))
f:write(table.concat(out, '\n'))
f:write('\n')
f:close()

print(('wrote %s (%d tables)'):format(OUT, #order))
