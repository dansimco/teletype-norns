-- ops/variables.lua -- port of teletype/src/ops/variables.c
--
-- A, B, C, D, X, Y, Z, T are plain int16 cells. The interesting ones are the
-- variables with side effects on read: O and DRUNK advance themselves, FLIP
-- toggles, TIME is derived from the tick counter, and I/J/K live in the
-- execution frame rather than the scene.

local exec = require 'exec'
local helpers = require 'helpers'
local registry = require 'ops.registry'
local st = require 'state'

local impl = registry.impl

--- a plain get/set variable backed by a field of ss.variables
local function simple(name, field)
  impl(name,
    function(ss, _es, cs) cs:push(ss.variables[field]) end,
    function(ss, _es, cs) ss.variables[field] = cs:pop() end)
end

simple('A', 'a')
simple('B', 'b')
simple('C', 'c')
simple('D', 'd')
simple('X', 'x')
simple('Y', 'y')
simple('Z', 'z')
simple('T', 't')
simple('DRUNK.MAX', 'drunk_max')
simple('DRUNK.MIN', 'drunk_min')
simple('DRUNK.WRAP', 'drunk_wrap')
simple('O.INC', 'o_inc')
simple('O.MAX', 'o_max')
simple('O.MIN', 'o_min')
simple('O.WRAP', 'o_wrap')

-- TIME -----------------------------------------------------------------------
-- TIME is not stored; it is a delta from the tick counter. Setting it stores
-- an *offset* so the counter keeps running. With TIME.ACT off, the field holds
-- a literal value instead, and toggling ACT converts between the two.

impl('TIME',
  function(ss, _es, cs)
    local delta = (ss.variables.time_act ~= 0)
      and (exec.io.get_ticks() - ss.variables.time)
      or ss.variables.time
    cs:push(delta & 0x7fff)
  end,
  function(ss, _es, cs)
    local new_time = cs:pop()
    ss.variables.time = (ss.variables.time_act ~= 0)
      and (exec.io.get_ticks() - new_time)
      or new_time
  end)

impl('TIME.ACT',
  function(ss, _es, cs)
    cs:push(ss.variables.time_act ~= 0 and 1 or 0)
  end,
  function(ss, _es, cs)
    local act = cs:pop()
    local on = act ~= 0
    -- no-op if the state is unchanged: the conversion below is not idempotent
    if on == (ss.variables.time_act ~= 0) then return end
    ss.variables.time_act = on and 1 or 0
    ss.variables.time = exec.io.get_ticks() - ss.variables.time
  end)

-- LAST -----------------------------------------------------------------------

impl('LAST', function(ss, _es, cs)
  local script_number = cs:pop() - 1
  if script_number < -1 or script_number >= st.EDITABLE_SCRIPT_COUNT then
    cs:push(0)
    return
  end
  -- in LIVE mode SCRIPT reads 0, so `LAST 0` reports time since INIT
  if script_number == -1 then script_number = st.INIT_SCRIPT end
  cs:push(exec.get_script_last(ss, script_number))
end)

-- self-advancing variables ---------------------------------------------------

impl('DRUNK',
  function(ss, _es, cs)
    local v = ss.variables
    local r = ss.rand_states.drunk.rand
    -- the value is pinned into range *before* being returned, so changing
    -- DRUNK.MIN/MAX takes effect on the next read
    local current = helpers.normalise_value(v.drunk_min, v.drunk_max,
      v.drunk_wrap, v.drunk)
    cs:push(current)
    -- random walk of -1, 0 or +1
    local next_value = current + (r:next() % 3) - 1
    v.drunk = helpers.normalise_value(v.drunk_min, v.drunk_max, v.drunk_wrap,
      next_value)
  end,
  function(ss, _es, cs) ss.variables.drunk = cs:pop() end)

impl('FLIP',
  function(ss, _es, cs)
    local flip = ss.variables.flip
    cs:push(flip)
    ss.variables.flip = (flip == 0) and 1 or 0
  end,
  function(ss, _es, cs)
    ss.variables.flip = (cs:pop() ~= 0) and 1 or 0
  end)

impl('O',
  function(ss, _es, cs)
    local v = ss.variables
    local current = helpers.normalise_value(v.o_min, v.o_max, v.o_wrap, v.o)
    cs:push(current)
    v.o = helpers.normalise_value(v.o_min, v.o_max, v.o_wrap, current + v.o_inc)
  end,
  function(ss, _es, cs) ss.variables.o = cs:pop() end)

-- execution-frame variables --------------------------------------------------
-- I is the loop counter; the L mod hands out a reference to this same cell, so
-- a loop body can assign to I to skip or rewind.

impl('I',
  function(_ss, es, cs) cs:push(es:vars().i) end,
  function(_ss, es, cs) es:vars().i = cs:pop() end)

-- J and K are per-script scratch variables, indexed by the running script
local function per_script(name, field)
  impl(name,
    function(ss, es, cs)
      cs:push(ss.variables[field][es:vars().script_number] or 0)
    end,
    function(ss, es, cs)
      local value = cs:pop()
      local sn = es:vars().script_number
      if sn < 0 or sn >= st.TOTAL_SCRIPT_COUNT then return end
      ss.variables[field][sn] = value
    end)
end

per_script('J', 'j')
per_script('K', 'k')
