-- state.lua
--
-- Port of teletype/src/state.h + state.c: the three pieces of state the
-- runtime threads through everything.
--
--   scene_state    the scene -- variables, patterns, scripts, delays, turtle.
--                  this is what a .txt scene file serialises.
--   exec_state     a call stack of execution frames. SCRIPT, $F and $L push a
--                  frame; IF/ELSE chains and the loop variable I live in one.
--   command_state  the value stack for a single sub-command. 16 deep, int16.
--
-- Arrays that the C indexes from 0 (cv[4], tr[4], patterns[4], scripts[12])
-- are kept 0-indexed here too, so op code transcribes without an off-by-one
-- at every access.

local int16 = require 'int16'
local helpers = require 'helpers'
local Random = require 'random'
local scale = require 'scale'

local M = {}

-- ------------------------------------------------------------- constants
-- teletype/src/state.h:16
M.STACK_SIZE = 16
M.CV_COUNT = 4
M.Q_LENGTH = 64
M.TR_COUNT = 4
M.TRIGGER_INPUTS = 8
M.DELAY_SIZE = 64
M.STACK_OP_SIZE = 16
M.PATTERN_COUNT = 4
M.PATTERN_LENGTH = 64
M.SCRIPT_MAX_COMMANDS = 6
M.EXEC_DEPTH = 8
M.WHILE_DEPTH = 10000
M.RAND_STATES_COUNT = 5
M.MAX_MIDI_EVENTS = 10
M.METRO_MIN_MS = 25
M.METRO_MIN_UNSUPPORTED_MS = 2
M.NB_NBX_SCALES = 16

-- teletype/src/script.h
M.REGULAR_SCRIPT_COUNT = 8
M.METRO_SCRIPT = 8
M.INIT_SCRIPT = 9
M.EDITABLE_SCRIPT_COUNT = 10
M.DELAY_SCRIPT = 10
M.LIVE_SCRIPT = 11
M.TOTAL_SCRIPT_COUNT = 12
M.NO_SCRIPT = 12

-- ============================================================ command state

local CommandState = {}
CommandState.__index = CommandState
M.CommandState = CommandState

function CommandState.new()
  return setmetatable({ values = {}, top = 0 }, CommandState)
end

function CommandState:init()
  self.top = 0
end

-- The C cs_push/cs_pop are unchecked -- popping an empty stack reads whatever
-- is below it. validate() is supposed to make that unreachable, so rather than
-- reproduce undefined behaviour we return a deterministic 0 and saturate at
-- the top. If this ever fires, a validate() divergence is the real bug.
function CommandState:push(v)
  if self.top >= M.STACK_SIZE then return end
  self.top = self.top + 1
  self.values[self.top] = int16.wrap(v)
end

function CommandState:pop()
  if self.top <= 0 then return 0 end
  local v = self.values[self.top]
  self.top = self.top - 1
  return v
end

function CommandState:size()
  return self.top
end

-- ============================================================== exec state

local ExecState = {}
ExecState.__index = ExecState
M.ExecState = ExecState

local function new_exec_vars()
  return {
    if_else_condition = false,
    i = 0,
    while_continue = false,
    while_depth = 0,
    breaking = false,
    script_number = M.NO_SCRIPT,
    line_number = 0,
    delayed = false,
    fparam1 = 0, fparam2 = 0, fresult = 0, fresult_set = false,
  }
end

--- teletype/src/state.c:626
function ExecState.new()
  local es = setmetatable({ variables = {}, exec_depth = 0, overflow = false },
    ExecState)
  for i = 1, M.EXEC_DEPTH do es.variables[i] = new_exec_vars() end
  return es
end

function ExecState:depth()
  return self.exec_depth
end

--- push a frame. teletype/src/state.c:645
-- note what is and is not inherited: if_else_condition and i carry down from
-- the parent (so a SCRIPT called from inside an IF sees the chain state, and
-- a nested loop sees the outer I), while breaking and the while counters
-- reset. getting this wrong produces bugs that only show up several levels in.
function ExecState:push(param1, param2)
  if self.exec_depth < M.EXEC_DEPTH then
    local v = self.variables[self.exec_depth + 1]
    v.delayed = false
    v.while_depth = 0
    v.while_continue = false
    if self.exec_depth > 0 then
      local parent = self.variables[self.exec_depth]
      v.if_else_condition = parent.if_else_condition
      v.i = parent.i
    else
      v.if_else_condition = true
      v.i = 0
    end
    v.breaking = false
    v.fparam1 = param1 or 0
    v.fparam2 = param2 or 0
    self.exec_depth = self.exec_depth + 1
  else
    -- once set, overflow is never cleared: it permanently disables further
    -- SCRIPT calls, which is the recursion guard
    self.overflow = true
  end
  return self.exec_depth
end

function ExecState:pop()
  if self.exec_depth > 0 then self.exec_depth = self.exec_depth - 1 end
  return self.exec_depth
end

--- the current frame. teletype/src/state.c:690
function ExecState:vars()
  return self.variables[self.exec_depth]
end

--- teletype/src/state.c:677 -- a delayed command keeps its originating script
function ExecState:set_script_number(n)
  local v = self:vars()
  if not v.delayed then v.script_number = n end
end

function ExecState:set_line_number(n)
  self:vars().line_number = n
end

function ExecState:get_line_number()
  return self:vars().line_number
end

-- ============================================================= scene state

local SceneState = {}
SceneState.__index = SceneState
M.SceneState = SceneState

local function new_every_count()
  return { count = 0, mod = 1, skip = false }
end

local function new_script()
  local s = { l = 0, c = {}, every = {}, last_time = 0 }
  for i = 0, M.SCRIPT_MAX_COMMANDS - 1 do
    s.c[i] = { length = 0, separator = -1, data = {}, comment = false }
    s.every[i] = new_every_count()
  end
  return s
end

local function new_pattern()
  local p = { idx = 0, len = 0, wrap = 1, start = 0, ['end'] = 63, val = {} }
  for i = 0, M.PATTERN_LENGTH - 1 do p.val[i] = 0 end
  return p
end

--- default variables. teletype/src/state.c:35
-- anything not named here is zero, matching the C designated initialiser.
local function new_variables()
  local v = {
    a = 1, b = 2, c = 3, d = 4,
    x = 0, y = 0, z = 0, t = 0,
    j = {}, k = {},
    cv = {}, cv_off = {}, cv_slew = {},
    drunk = 0, drunk_max = 255, drunk_min = 0, drunk_wrap = 0,
    flip = 0,
    ['in'] = 0,
    m = 1000, m_act = 1,
    mutes = {},
    o = 0, o_inc = 1, o_min = 0, o_max = 63, o_wrap = 1,
    p_n = 0,
    param = 0,
    q = {}, q_n = 1, q_grow = 0,
    r_min = 0, r_max = 16383,
    n_scale_bits = {}, n_scale_root = {},
    scene = 0,
    script_pol = {},
    time = 0, time_act = 1,
    tr = {}, tr_pol = {}, tr_time = {},
    seed = 0,
    in_range = { 0, 16383 },
    param_range = { 0, 16383 },
  }
  for i = 0, M.TOTAL_SCRIPT_COUNT - 1 do v.j[i] = 0; v.k[i] = 0 end
  for i = 0, M.CV_COUNT - 1 do
    v.cv[i] = 0; v.cv_off[i] = 0; v.cv_slew[i] = 1
  end
  for i = 0, M.TR_COUNT - 1 do
    v.tr[i] = 0; v.tr_pol[i] = 1; v.tr_time[i] = 100
  end
  for i = 0, M.TRIGGER_INPUTS - 1 do v.script_pol[i] = 1; v.mutes[i] = false end
  for i = 0, M.Q_LENGTH - 1 do v.q[i] = 0 end
  -- the default N.B scale is a bit-reversed major scale mask
  local major = helpers.bit_reverse(tonumber('101011010101', 2), 12)
  for i = 0, M.NB_NBX_SCALES - 1 do
    v.n_scale_bits[i] = major
    v.n_scale_root[i] = 0
  end
  return v
end

--- teletype/src/state.c:12
-- `seed` selects the RNG seeding. the C uses rand() from the C library, which
-- is neither reproducible nor available here; an explicit seed keeps headless
-- runs deterministic, and the device passes a time-derived one.
function SceneState.new(seed)
  local ss = setmetatable({}, SceneState)
  ss.initializing = true
  ss.variables = new_variables()

  ss.patterns = {}
  for i = 0, M.PATTERN_COUNT - 1 do ss.patterns[i] = new_pattern() end

  ss.scripts = {}
  for i = 0, M.TOTAL_SCRIPT_COUNT - 1 do ss.scripts[i] = new_script() end

  ss.delay = {
    commands = {}, time = {}, origin_script = {}, origin_i = {},
    origin_fparam1 = {}, origin_fparam2 = {}, count = 0,
  }
  for i = 0, M.DELAY_SIZE - 1 do ss.delay.time[i] = 0 end

  ss.stack_op = { commands = {}, top = 0 }

  ss.every_last = false
  ss.i2c_op_address = -1

  -- IN/PARAM calibration and the derived scales. the scales are cached rather
  -- than recomputed per read, matching ss_update_*_scale in the C.
  ss.cal = scale.new_cal()
  ss.variables.in_scale =
    scale.init(ss.cal.i_min, ss.cal.i_max, ss.variables.in_range[1],
      ss.variables.in_range[2])
  ss.variables.param_scale =
    scale.init(ss.cal.p_min, ss.cal.p_max, ss.variables.param_range[1],
      ss.variables.param_range[2])

  -- five independently seedable generators: rand, prob, toss, pattern, drunk
  ss.rand_states = {}
  local names = { 'rand', 'prob', 'toss', 'pattern', 'drunk' }
  for i, name in ipairs(names) do
    local s = (seed or 0) + i
    ss.rand_states[name] = { seed = s, rand = Random.new(s) }
  end

  ss.midi = M.new_midi_state()
  ss.turtle = M.new_turtle_state()

  return ss
end

--- teletype/src/state.c:172
function M.new_midi_state()
  local m = {
    on_script = -1, off_script = -1, cc_script = -1, clk_script = -1,
    start_script = -1, stop_script = -1, continue_script = -1,
    last_event_type = 0, last_channel = 0, last_note = 0,
    last_velocity = 0, last_controller = 0, last_cc = 0,
    on_count = 0, off_count = 0, cc_count = 0,
    clock_div = 24,   -- one MIDI clock message per quarter note
    on_channel = {}, note_on = {}, note_vel = {},
    off_channel = {}, note_off = {},
    cc_channel = {}, cn = {}, cc = {},
  }
  for i = 0, M.MAX_MIDI_EVENTS - 1 do
    m.on_channel[i] = 0; m.note_on[i] = 0; m.note_vel[i] = 0
    m.off_channel[i] = 0; m.note_off[i] = 0
    m.cc_channel[i] = 0; m.cn[i] = 0; m.cc[i] = 0
  end
  return m
end

--- teletype/src/turtle.c turtle_init. position is Q6.9 fixed point, and the
--- defaults are BUMP mode, heading 180, speed 100.
function M.new_turtle_state()
  return require('turtle').new()
end

-- ---------------------------------------------------------------- patterns

function SceneState:pattern(n)
  return self.patterns[helpers.normalise_value(0, M.PATTERN_COUNT - 1, 0, n)]
end

-- ----------------------------------------------------------------- scripts

function SceneState:script_len(idx)
  return self.scripts[idx].l
end

function SceneState:script_command(idx, c_idx)
  return self.scripts[idx].c[c_idx]
end

function SceneState:script_comment(idx, c_idx)
  local c = self.scripts[idx].c[c_idx]
  return c and c.comment or false
end

function SceneState:clear_script(idx)
  local s = self.scripts[idx]
  for i = 0, M.SCRIPT_MAX_COMMANDS - 1 do
    s.c[i] = { length = 0, separator = -1, data = {}, comment = false }
  end
  s.l = 0
end

function SceneState:overwrite_script_command(idx, c_idx, cmd)
  local command = require 'command'
  self.scripts[idx].c[c_idx] = command.copy(cmd)
  if c_idx >= self.scripts[idx].l then
    self.scripts[idx].l = c_idx + 1
  end
end

--- every_count_t for a (script, line). teletype/src/state.h:336
function SceneState:every(idx, line)
  return self.scripts[idx].every[line]
end

return M
