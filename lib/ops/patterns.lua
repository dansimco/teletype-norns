-- ops/patterns.lua -- port of teletype/src/ops/patterns.c
--
-- Four patterns of 64 values, each with its own length, playhead, wrap flag
-- and start/end loop points.
--
-- Every op comes in two forms: `P.X` operates on the working pattern (the one
-- P.N selects) and `PN.X` takes the pattern number as an extra leading
-- argument. Since the first pop is always the leftmost argument, the only
-- difference is where `pn` comes from -- so each op is written once against a
-- `pn` and registered twice by `pair()`.

local exec = require 'exec'
local int16 = require 'int16'
local registry = require 'ops.registry'
local st = require 'state'

local impl = registry.impl

local PATTERN_COUNT = st.PATTERN_COUNT
local PATTERN_LENGTH = st.PATTERN_LENGTH

-- helpers --------------------------------------------------------------------

--- clamp a pattern number to 0..3. patterns.c:12
local function normalise_pn(pn)
  if pn < 0 then return 0 end
  if pn >= PATTERN_COUNT then return PATTERN_COUNT - 1 end
  return pn
end

--- clamp an index, treating negatives as offsets from the end. patterns.c:23
local function normalise_idx(ss, pn, idx)
  local len = ss.patterns[pn].len
  if idx < 0 then
    if idx == len then idx = 0
    elseif idx < -len then idx = 0
    else idx = len + idx end
  end
  if idx >= PATTERN_LENGTH then idx = PATTERN_LENGTH - 1 end
  return idx
end

--- modulo into [a, b]. a local copy in patterns.c:39, same shape as WRAP.
local function wrap_value(value, a, b)
  local i, c = value, 0
  if a < b then
    c = b - a + 1
    while i >= b do i = i - c end
    while i < a do i = i + c end
  else
    c = a - b + 1
    while i >= a do i = i - c end
    while i < b do i = i + c end
  end
  return i
end

local function get_val(ss, pn, idx) return ss.patterns[pn].val[idx] or 0 end
local function set_val(ss, pn, idx, v)
  if idx >= 0 and idx < PATTERN_LENGTH then
    ss.patterns[pn].val[idx] = int16.wrap(v)
  end
end

--- register a `P.X` / `PN.X` pair.
-- `body` receives (ss, es, cs, pn) with pn already resolved, so it only has to
-- pop its own arguments. `params` is the count for the P. form; the PN. form
-- takes one more.
local function pair(base, get_body, set_body)
  local function wrap_body(body, explicit)
    if not body then return nil end
    return function(ss, es, cs)
      local pn
      if explicit then
        pn = normalise_pn(cs:pop())
      else
        pn = normalise_pn(ss.variables.p_n)
      end
      return body(ss, es, cs, pn)
    end
  end

  -- the bare value ops are "P" and "PN"; everything else is dotted
  local p_name = base == '' and 'P' or ('P.' .. base)
  local pn_name = base == '' and 'PN' or ('PN.' .. base)

  impl(p_name, wrap_body(get_body, false), wrap_body(set_body, false))
  impl(pn_name, wrap_body(get_body, true), wrap_body(set_body, true))
end

-- P.N: which pattern the P. forms address ------------------------------------

impl('P.N',
  function(ss, _es, cs) cs:push(ss.variables.p_n) end,
  function(ss, _es, cs)
    local a = cs:pop()
    if a < 0 then a = 0 elseif a >= PATTERN_COUNT then a = PATTERN_COUNT - 1 end
    ss.variables.p_n = a
  end)

-- value access ----------------------------------------------------------------

pair('',
  function(ss, _es, cs, pn)
    cs:push(get_val(ss, pn, normalise_idx(ss, pn, cs:pop())))
  end,
  function(ss, _es, cs, pn)
    local idx = normalise_idx(ss, pn, cs:pop())
    set_val(ss, pn, idx, cs:pop())
    exec.io.pattern_updated()
  end)

pair('HERE',
  function(ss, _es, cs, pn)
    cs:push(get_val(ss, pn, ss.patterns[pn].idx))
  end,
  function(ss, _es, cs, pn)
    set_val(ss, pn, ss.patterns[pn].idx, cs:pop())
    exec.io.pattern_updated()
  end)

-- geometry --------------------------------------------------------------------

pair('L',
  function(ss, _es, cs, pn) cs:push(ss.patterns[pn].len) end,
  function(ss, _es, cs, pn)
    local l = cs:pop()
    if l < 0 then l = 0 elseif l > PATTERN_LENGTH then l = PATTERN_LENGTH end
    ss.patterns[pn].len = l
    exec.io.pattern_updated()
  end)

pair('WRAP',
  function(ss, _es, cs, pn) cs:push(ss.patterns[pn].wrap) end,
  function(ss, _es, cs, pn)
    ss.patterns[pn].wrap = cs:pop() >= 1 and 1 or 0
  end)

pair('START',
  function(ss, _es, cs, pn) cs:push(ss.patterns[pn].start) end,
  function(ss, _es, cs, pn)
    ss.patterns[pn].start = normalise_idx(ss, pn, cs:pop())
    exec.io.pattern_updated()
  end)

pair('END',
  function(ss, _es, cs, pn) cs:push(ss.patterns[pn]['end']) end,
  function(ss, _es, cs, pn)
    ss.patterns[pn]['end'] = normalise_idx(ss, pn, cs:pop())
    exec.io.pattern_updated()
  end)

pair('I',
  function(ss, _es, cs, pn) cs:push(ss.patterns[pn].idx) end,
  function(ss, _es, cs, pn)
    local i = normalise_idx(ss, pn, cs:pop())
    local len = ss.patterns[pn].len
    if i < 0 or len == 0 then ss.patterns[pn].idx = 0
    elseif i >= len then ss.patterns[pn].idx = len - 1
    else ss.patterns[pn].idx = i end
    exec.io.pattern_updated()
  end)

-- playhead movement -----------------------------------------------------------

--- advance the playhead, honouring START/END/WRAP/L. patterns.c:384
local function next_inc_i(ss, pn)
  local p = ss.patterns[pn]
  local idx = p.idx
  if idx == (p.len - 1) or idx == p['end'] then
    if p.wrap ~= 0 then idx = p.start end
  else
    idx = idx + 1
  end
  if idx > p.len or idx < 0 or idx >= PATTERN_LENGTH then idx = 0 end
  p.idx = idx
end

--- retreat the playhead. patterns.c:452
local function prev_dec_i(ss, pn)
  local p = ss.patterns[pn]
  local idx = p.idx
  if idx == 0 or idx == p.start then
    if p.wrap ~= 0 then
      if p['end'] < p.len then idx = p['end'] else idx = p.len - 1 end
    end
  else
    idx = idx - 1
  end
  p.idx = idx
end

local function step_pair(base, move)
  pair(base,
    function(ss, _es, cs, pn)
      move(ss, pn)
      cs:push(get_val(ss, pn, ss.patterns[pn].idx))
      exec.io.pattern_updated()
    end,
    function(ss, _es, cs, pn)
      local a = cs:pop()
      move(ss, pn)
      set_val(ss, pn, ss.patterns[pn].idx, a)
      exec.io.pattern_updated()
    end)
end

step_pair('NEXT', next_inc_i)
step_pair('PREV', prev_dec_i)

-- insertion and removal -------------------------------------------------------

pair('INS', function(ss, _es, cs, pn)
  local idx = normalise_idx(ss, pn, cs:pop())
  local val = cs:pop()
  local p = ss.patterns[pn]
  if p.len >= idx then
    for i = p.len, idx + 1, -1 do set_val(ss, pn, i, get_val(ss, pn, i - 1)) end
    if p.len < PATTERN_LENGTH - 1 then p.len = p.len + 1 end
  end
  set_val(ss, pn, idx, val)
  exec.io.pattern_updated()
end)

pair('RM', function(ss, _es, cs, pn)
  local idx_arg = cs:pop()
  local p = ss.patterns[pn]
  local ret = 0
  if p.len > 0 then
    local idx = normalise_idx(ss, pn, idx_arg)
    ret = get_val(ss, pn, idx)
    if idx < p.len then
      for i = idx, p.len - 1 do set_val(ss, pn, i, get_val(ss, pn, i + 1)) end
      p.len = p.len - 1
    end
  end
  cs:push(ret)
  exec.io.pattern_updated()
end)

pair('PUSH', function(ss, _es, cs, pn)
  local val = cs:pop()
  local p = ss.patterns[pn]
  if p.len < PATTERN_LENGTH then
    set_val(ss, pn, p.len, val)
    p.len = p.len + 1
  end
  exec.io.pattern_updated()
end)

pair('POP', function(ss, _es, cs, pn)
  local p = ss.patterns[pn]
  if p.len > 0 then
    p.len = p.len - 1
    cs:push(get_val(ss, pn, p.len))
  else
    cs:push(0)
  end
  exec.io.pattern_updated()
end)

-- search ----------------------------------------------------------------------
-- MIN and MAX return the *index* of the extreme value between START and END,
-- not the value itself.

local function extreme(compare)
  return function(ss, _es, cs, pn)
    local p = ss.patterns[pn]
    local pos = p.start
    local val = get_val(ss, pn, pos)
    for i = p.start + 1, p['end'] do
      local temp = get_val(ss, pn, i)
      if compare(temp, val) then pos = i; val = temp end
    end
    cs:push(pos)
  end
end

pair('MIN', extreme(function(a, b) return a < b end))
pair('MAX', extreme(function(a, b) return a > b end))

pair('RND', function(ss, _es, cs, pn)
  local p = ss.patterns[pn]
  if p['end'] < p.start then cs:push(0) return end
  local span = p['end'] - p.start + 1
  local idx = int16.imod(ss.rand_states.pattern.rand:next(), span) + p.start
  cs:push(get_val(ss, pn, idx))
end)

-- reordering ------------------------------------------------------------------
-- all of these operate on the START..END window, not the whole pattern

pair('SHUF', function(ss, _es, _cs, pn)
  local p = ss.patterns[pn]
  if p['end'] < p.start then return end
  -- Fisher-Yates downward from END
  for i = p['end'], p.start + 1, -1 do
    local draw = int16.imod(ss.rand_states.pattern.rand:next(),
      i - p.start + 1) + p.start
    local xchg = get_val(ss, pn, draw)
    set_val(ss, pn, draw, get_val(ss, pn, i))
    set_val(ss, pn, i, xchg)
  end
  exec.io.pattern_updated()
end)

local function reverse(ss, pn, start, finish)
  if finish < start then return end
  local midpt = (finish - start) // 2
  for i = 0, midpt do
    local xchg = get_val(ss, pn, finish - i)
    set_val(ss, pn, finish - i, get_val(ss, pn, start + i))
    set_val(ss, pn, start + i, xchg)
  end
  exec.io.pattern_updated()
end

pair('REV', function(ss, _es, _cs, pn)
  reverse(ss, pn, ss.patterns[pn].start, ss.patterns[pn]['end'])
end)

pair('ROT', function(ss, _es, cs, pn)
  local shift = cs:pop()
  local p = ss.patterns[pn]
  local start, finish = p.start, p['end']
  if finish < start then return end
  local len = finish - start + 1
  -- rotation as three reversals
  if shift < 0 then
    shift = int16.imod(-shift, len)
    if shift == 0 then return end
    reverse(ss, pn, start, start + shift - 1)
    reverse(ss, pn, start + shift, finish)
    reverse(ss, pn, start, finish)
  else
    shift = int16.imod(shift, len)
    if shift == 0 then return end
    reverse(ss, pn, finish - shift + 1, finish)
    reverse(ss, pn, start, finish - shift)
    reverse(ss, pn, start, finish)
  end
end)

-- NB: patterns.c also defines P.CYC / PN.CYC, but they are never added to
-- tele_ops[] and have no entry in the lexer, so the language has no such op.
-- Left unimplemented deliberately; the coverage test would flag it otherwise.

-- arithmetic on a single step --------------------------------------------------

local function add_sub(sign, wrapped)
  return function(ss, _es, cs, pn)
    local idx = normalise_idx(ss, pn, cs:pop())
    local delta = cs:pop()
    local value = get_val(ss, pn, idx) + sign * delta
    if wrapped then
      local min, max = cs:pop(), cs:pop()
      value = wrap_value(int16.wrap(value), min, max)
    end
    set_val(ss, pn, idx, value)
    exec.io.pattern_updated()
  end
end

pair('+', add_sub(1, false))
pair('+W', add_sub(1, true))
pair('-', add_sub(-1, false))
pair('-W', add_sub(-1, true))

-- P.MAP / PN.MAP ---------------------------------------------------------------
-- Iterate START..END with I bound to each value; if the command returns a
-- value it is written back. This is the one mod that mutates a pattern.

local function p_map(ss, es, post, pn)
  pn = normalise_pn(pn)
  local p = ss.patterns[pn]
  if p.start >= p['end'] then return end
  for idx = p.start, p['end'] do
    es:vars().i = get_val(ss, pn, idx)
    local has_value, value = exec.process_command(ss, es, post)
    if has_value then set_val(ss, pn, idx, value) end
  end
  exec.io.pattern_updated()
end

registry.impl_mod('P.MAP', function(ss, es, _cs, post)
  p_map(ss, es, post, ss.variables.p_n)
end)

registry.impl_mod('PN.MAP', function(ss, es, cs, post)
  p_map(ss, es, post, cs:pop())
end)
