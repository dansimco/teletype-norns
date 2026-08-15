-- ops/turtle_ops.lua -- port of teletype/src/ops/turtle.c
--
-- The turtle reads and writes pattern data by position rather than by index,
-- treating the four patterns as a 4x64 grid. lib/turtle.lua holds the
-- fixed-point movement; this file is just the op surface over it.

local exec = require 'exec'
local registry = require 'ops.registry'
local st = require 'state'
local turtle = require 'turtle'

local impl = registry.impl

--- the pattern cell the turtle is standing on, or nil if it is off the grid
local function cell(t)
  local x, y = turtle.get_x(t), turtle.get_y(t)
  if x > 3 or x < 0 or y > 63 or y < 0 then return nil end
  return x, y
end

-- value under the turtle ---------------------------------------------------------

impl('@',
  function(ss, _es, cs)
    local x, y = cell(ss.turtle)
    cs:push(x and ss.patterns[x].val[y] or 0)
  end,
  function(ss, _es, cs)
    local v = cs:pop()
    local x, y = cell(ss.turtle)
    if x then ss.patterns[x].val[y] = v end
    exec.io.pattern_updated()
  end)

-- position ------------------------------------------------------------------------

impl('@X',
  function(ss, _es, cs) cs:push(turtle.get_x(ss.turtle)) end,
  function(ss, _es, cs)
    turtle.set_x(ss.turtle, cs:pop())
    exec.io.pattern_updated()
  end)

impl('@Y',
  function(ss, _es, cs) cs:push(turtle.get_y(ss.turtle)) end,
  function(ss, _es, cs)
    turtle.set_y(ss.turtle, cs:pop())
    exec.io.pattern_updated()
  end)

impl('@MOVE', function(ss, _es, cs)
  local x, y = cs:pop(), cs:pop()
  turtle.move(ss.turtle, x, y)
  exec.io.pattern_updated()
end)

-- fence ---------------------------------------------------------------------------

impl('@F', function(ss, _es, cs)
  local x1, y1, x2, y2 = cs:pop(), cs:pop(), cs:pop(), cs:pop()
  turtle.set_fence(ss.turtle, x1, y1, x2, y2)
  exec.io.pattern_updated()
end)

--- one fence edge. the C stores these in a uint8_t, so a negative becomes 0
--- and anything larger wraps into a byte before correct_fence clamps it.
local function fence_edge(name, field)
  impl(name,
    function(ss, _es, cs) cs:push(ss.turtle.fence[field]) end,
    function(ss, _es, cs)
      local v = cs:pop()
      ss.turtle.fence[field] = (v > 0 and v or 0) & 0xff
      turtle.correct_fence(ss.turtle)
      exec.io.pattern_updated()
    end)
end

fence_edge('@FX1', 'x1')
fence_edge('@FY1', 'y1')
fence_edge('@FX2', 'x2')
fence_edge('@FY2', 'y2')

-- movement --------------------------------------------------------------------------

impl('@SPEED',
  function(ss, _es, cs) cs:push(ss.turtle.speed) end,
  function(ss, _es, cs) ss.turtle.speed = cs:pop() end)

impl('@DIR',
  function(ss, _es, cs) cs:push(ss.turtle.heading) end,
  function(ss, _es, cs) turtle.set_heading(ss.turtle, cs:pop()) end)

impl('@STEP', function(ss, _es, _cs)
  turtle.step(ss.turtle)
  exec.io.pattern_updated()
end)

-- fence behaviour --------------------------------------------------------------------
-- the three modes are mutually exclusive; each op reads as a flag and setting
-- it to a true value selects that mode (setting it false does nothing).

local function mode_op(name, mode)
  impl(name,
    function(ss, _es, cs) cs:push(ss.turtle.mode == mode and 1 or 0) end,
    function(ss, _es, cs)
      if cs:pop() ~= 0 then turtle.set_mode(ss.turtle, mode) end
      exec.io.pattern_updated()
    end)
end

mode_op('@BUMP', turtle.BUMP)
mode_op('@WRAP', turtle.WRAP)
mode_op('@BOUNCE', turtle.BOUNCE)

-- script binding ------------------------------------------------------------------------

impl('@SCRIPT',
  function(ss, _es, cs)
    local s = ss.turtle.script_number
    cs:push(s == st.NO_SCRIPT and 0 or s + 1)
  end,
  function(ss, _es, cs)
    local sn = cs:pop() - 1
    if sn < 0 or sn >= st.EDITABLE_SCRIPT_COUNT then
      turtle.set_script(ss.turtle, st.NO_SCRIPT)
    else
      turtle.set_script(ss.turtle, sn)
    end
  end)

impl('@SHOW',
  -- the getter notifies too: reading @SHOW is how the tracker view is told to
  -- redraw with the turtle overlay
  function(ss, _es, cs)
    cs:push(ss.turtle.shown and 1 or 0)
    exec.io.pattern_updated()
  end,
  function(ss, _es, cs)
    ss.turtle.shown = cs:pop() ~= 0
    exec.io.pattern_updated()
  end)
