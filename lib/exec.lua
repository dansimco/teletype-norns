-- exec.lua
--
-- The runtime. Port of teletype/src/teletype.c: process_command(),
-- run_script*(), and tele_tick().
--
-- The evaluation rule, in one paragraph, because everything here follows from
-- it: a command is split at its PRE separator, and only the PRE runs -- the
-- MOD at position 1 receives the POST and decides whether and how often to run
-- it. What remains is split into `;`-separated sub-commands. Subs run left to
-- right; the words *within* a sub run right to left against a fresh 16-deep
-- int16 stack. An op invokes its setter rather than its getter iff it sits at
-- the sub's leftmost position, has a setter, and finds at least params+1
-- values on the stack. That last clause is the whole assignment mechanism:
-- `CV 1 V 5` sets, `CV 1` reads, and `X CV 1` reads because CV is no longer
-- leftmost.

local command = require 'command'
local registry = require 'ops.registry'
local st = require 'state'

local M = {}

-- The io backend, satisfying the teletype_io.h surface. Swapped for a real one
-- on device; defaults to no-ops so the core is testable headlessly.
M.io = require 'io.null_io'

function M.set_io(io_impl)
  M.io = io_impl
end

-- ------------------------------------------------------------ process_command

--- run one parsed command. teletype/src/teletype.c:230
-- returns has_value, value.
function M.process_command(ss, es, cmd)
  local cs = st.CommandState.new()

  -- 1. if there is a PRE separator, only the PRE executes now.
  --    `separator` is the C's 0-based index, so the PRE occupies lua words
  --    1..separator.
  local start_idx = 1
  local end_idx = (cmd.separator == -1) and cmd.length or cmd.separator

  -- 2. locate the sub-commands
  local subs = {}
  local sub_start = start_idx
  for idx = start_idx, end_idx do
    if cmd.data[idx].tag == command.SUB_SEP and idx > sub_start then
      subs[#subs + 1] = { first = sub_start, last = idx - 1 }
      sub_start = idx + 1
    end
  end
  if end_idx >= sub_start then
    subs[#subs + 1] = { first = sub_start, last = end_idx }
  end

  -- 3. execute each sub left to right, words right to left
  for _, sub in ipairs(subs) do
    if es:vars().breaking then break end

    -- reinitialised per sub: a value left over from the previous sub would
    -- otherwise satisfy the set-dispatch test and turn a read into a write
    cs:init()

    for idx = sub.last, sub.first, -1 do
      local word = cmd.data[idx]
      local tag, value = word.tag, word.value

      if command.is_number[tag] then
        cs:push(value)

      elseif tag == command.OP then
        local op = registry.ops[value]
        if idx == sub.first and op.set ~= nil
            and cs:size() >= op.params + 1 then
          op.set(ss, es, cs)
        else
          op.get(ss, es, cs)
        end

      elseif tag == command.MOD then
        local mod = registry.mods[value]
        local post = command.copy_post(cmd)
        mod.func(ss, es, cs, post)
      end
    end
  end

  -- 4. a single leftover value is the command's result -- what live mode
  --    prints, what $F returns, what P.MAP writes back
  if cs:size() > 0 then
    return true, cs:pop()
  end
  return false, 0
end

-- --------------------------------------------------------------- run_script

--- teletype/src/teletype.c:152
local function run_range(ss, es, script_no, line1, line2)
  local has_value, value = false, 0

  es:set_script_number(script_no)

  for i = line1, line2 do
    if i >= ss:script_len(script_no) then break end

    es:set_line_number(i)

    -- commented lines do not run
    if not ss:script_comment(script_no, i) then
      if es:vars().breaking then break end

      -- W is implemented out here rather than inside the mod: the mod runs the
      -- POST once and raises while_continue, and this loop re-runs the line.
      repeat
        has_value, value =
          M.process_command(ss, es, ss:script_command(script_no, i))
      until not es:vars().while_continue or es:vars().breaking
    end
  end

  es:vars().breaking = false
  M.update_script_last(ss, script_no)

  return has_value, value
end

--- run a whole script in a fresh execution context. teletype/src/teletype.c:143
function M.run_script(ss, script_no)
  local es = st.ExecState.new()
  es:push()
  return M.run_script_with_exec_state(ss, es, script_no)
end

function M.run_script_with_exec_state(ss, es, script_no)
  return run_range(ss, es, script_no, 0, st.SCRIPT_MAX_COMMANDS - 1)
end

function M.run_line_with_exec_state(ss, es, script_no, line_no)
  return run_range(ss, es, script_no, line_no, line_no)
end

--- $F variants: the result is the explicit FR value if one was set.
function M.run_fscript_with_exec_state(ss, es, script_no)
  local has_value, value = run_range(ss, es, script_no, 0,
    st.SCRIPT_MAX_COMMANDS - 1)
  local v = es:vars()
  if v.fresult_set then return true, v.fresult end
  return has_value, value
end

function M.run_fline_with_exec_state(ss, es, script_no, line_no)
  local has_value, value = run_range(ss, es, script_no, line_no, line_no)
  local v = es:vars()
  if v.fresult_set then return true, v.fresult end
  return has_value, value
end

-- --------------------------------------------------------------- script last

function M.update_script_last(ss, idx)
  ss.scripts[idx].last_time = M.io.get_ticks()
end

--- ms since a script last ran. teletype/src/state.c:428
function M.get_script_last(ss, idx)
  if idx < 0 or idx >= st.EDITABLE_SCRIPT_COUNT then return 0 end
  return (M.io.get_ticks() - ss.scripts[idx].last_time) & 0x7fff
end

-- ---------------------------------------------------------------------- tick

--- advance the delay queue by `time` ms. teletype/src/teletype.c:335
-- called at 10ms on hardware (RATE_CLOCK), which is the delay resolution.
function M.tick(ss, time)
  -- a turtle that moved to a new cell fires its script on the next tick
  if ss.turtle.stepped and ss.turtle.script_number ~= st.NO_SCRIPT then
    ss.turtle.stepped = false
    M.run_script(ss, ss.turtle.script_number)
  end

  for i = 0, st.DELAY_SIZE - 1 do
    if ss.delay.time[i] ~= 0 then
      ss.delay.time[i] = ss.delay.time[i] - time
      if ss.delay.time[i] <= 0 then
        -- upstream issue #80: 0 marks an empty slot, so a slot that is
        -- mid-execution is parked at 1. otherwise a DEL scheduled *by* this
        -- command could claim the slot while it is still running.
        ss.delay.time[i] = 1

        -- delayed commands execute through the scratch DELAY_SCRIPT so that
        -- they have a script number for THIS to resolve against
        ss:clear_script(st.DELAY_SCRIPT)
        ss:overwrite_script_command(st.DELAY_SCRIPT, 0, ss.delay.commands[i])

        local es = st.ExecState.new()
        es:push()
        local v = es:vars()
        -- `delayed` protects script_number from being overwritten by the
        -- DELAY_SCRIPT index as the runner descends
        v.delayed = true
        v.script_number = ss.delay.origin_script[i]
        v.i = ss.delay.origin_i[i]
        v.fparam1 = ss.delay.origin_fparam1[i]
        v.fparam2 = ss.delay.origin_fparam2[i]

        M.run_script_with_exec_state(ss, es, st.DELAY_SCRIPT)

        ss.delay.time[i] = 0
        ss.delay.count = ss.delay.count - 1
        if ss.delay.count == 0 then M.io.has_delays(false) end
      end
    end
  end
end

--- teletype/src/teletype.c:394 -- restore a TR output to its resting level
function M.tr_pulse_end(ss, i)
  ss.variables.tr[i] = (ss.variables.tr_pol[i] == 0) and 1 or 0
  M.io.tr(i, ss.variables.tr[i])
end

--- teletype/src/teletype.c:21
function M.clear_delays(ss)
  for i = 0, st.TR_COUNT - 1 do
    M.io.tr_pulse_clear(i)
    M.tr_pulse_end(ss, i)
  end
  for i = 0, st.DELAY_SIZE - 1 do ss.delay.time[i] = 0 end
  ss.delay.count = 0
  ss.stack_op.top = 0
  M.io.has_delays(false)
  M.io.has_stack(false)
end

return M
