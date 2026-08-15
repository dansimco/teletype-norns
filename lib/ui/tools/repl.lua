-- repl.lua -- a terminal Teletype, for driving the language core without norns.
--
-- Mirrors teletype/simulator/tt.c: the same scene state and evaluator the norns
-- script uses, with an io backend that prints what it would have done instead
-- of talking to a crow.
--
--   lua5.4 lib/tools/repl.lua                       empty scene
--   lua5.4 lib/tools/repl.lua ../teletype/presets/tt00.txt
--
-- Commands are teletype lines. Anything starting with `.` is a REPL command:
--
--   .1 .. .8 .m .i     run a script
--   .s N <line>        set line N (1-based) of the current script
--   .p [N]             show script N, or the current one
--   .e N               make script N current
--   .t [ms]            advance the delay clock (default 10ms)
--   .v                 show variables and outputs
--   .pat [n]           show pattern n
--   .load <file>       load a scene
--   .save <file>       write the scene back out
--   .q                 quit

package.path = table.concat({
  'lib/?.lua',
  (arg[0]:match('(.*)/lib/tools/repl%.lua$') or '.') .. '/lib/?.lua',
  package.path,
}, ';')

local exec = require 'exec'
local scene = require 'scene'
local st = require 'state'
local tokenizer = require 'tokenizer'
local validate = require 'validate'
require 'ops.init'

-- io backend: report everything, and keep a millisecond clock we advance by
-- hand so delays and TIME behave predictably
local io_impl = {}
do
  local base = require 'io.null_io'
  for k, v in pairs(base) do io_impl[k] = v end
  io_impl.ticks = 0
  io_impl.get_ticks = function() return io_impl.ticks end

  local function say(fmt, ...) print('    -> ' .. fmt:format(...)) end
  io_impl.tr = function(i, v) say('TR %s = %d', string.char(65 + i), v) end
  io_impl.tr_pulse = function(i, t)
    say('TR %s pulse %dms', string.char(65 + i), t)
  end
  io_impl.cv = function(i, v, slew)
    say('CV %d = %d (%.2fV)%s', i + 1, v, v / 1638.4,
      slew ~= 0 and ' slewed' or '')
  end
  io_impl.cv_slew = function(i, v) say('CV %d slew = %dms', i + 1, v) end
  io_impl.cv_off = function(i, v) say('CV %d offset = %d', i + 1, v) end
  io_impl.metro_updated = function() end
  io_impl.pattern_updated = function() end
  io_impl.mute = function() end
  io_impl.ii_tx = function(addr, data)
    say('i2c tx 0x%02x [%s]', addr, table.concat(data, ' '))
  end
  io_impl.ii_rx = function(addr, len)
    say('i2c rx 0x%02x (%d)', addr, len)
    local d = {}
    for i = 1, len do d[i] = 0 end
    return d
  end
end

exec.set_io(io_impl)

local ss = st.SceneState.new(os.time() & 0x7fff)
local text, grid = scene.new_text(), scene.new_grid()
local current_script = 0

local SCRIPT_NAMES = { [8] = 'M', [9] = 'I' }
local function script_label(n) return SCRIPT_NAMES[n] or tostring(n + 1) end

local function compile(line)
  local cmd, perr, pmsg = tokenizer.parse(line:upper())
  if perr ~= 'E_OK' then
    return nil, ('%s%s'):format(tokenizer.error_text(perr),
      pmsg ~= '' and (': ' .. pmsg) or '')
  end
  local verr, vmsg = validate.validate(cmd)
  if verr ~= 'E_OK' then
    return nil, ('%s%s'):format(tokenizer.error_text(verr),
      vmsg ~= '' and (': ' .. vmsg) or '')
  end
  return cmd
end

local function show_script(n)
  print(('#%s'):format(script_label(n)))
  if ss:script_len(n) == 0 then print('  (empty)') end
  for l = 0, ss:script_len(n) - 1 do
    print(('  %d: %s'):format(l + 1, tokenizer.print(ss:script_command(n, l))))
  end
end

local function show_vars()
  local v = ss.variables
  print(('A %-6d B %-6d C %-6d D %-6d'):format(v.a, v.b, v.c, v.d))
  print(('X %-6d Y %-6d Z %-6d T %-6d'):format(v.x, v.y, v.z, v.t))
  print(('M %-6d O %-6d DRUNK %-4d P.N %d'):format(v.m, v.o, v.drunk, v.p_n))
  print(('CV  %6d %6d %6d %6d'):format(v.cv[0], v.cv[1], v.cv[2], v.cv[3]))
  print(('TR  %6d %6d %6d %6d'):format(v.tr[0], v.tr[1], v.tr[2], v.tr[3]))
  print(('delays %d   stack %d'):format(ss.delay.count, ss.stack_op.top))
end

local function show_pattern(n)
  local p = ss.patterns[n]
  print(('pattern %d  len %d  wrap %d  start %d  end %d  idx %d')
    :format(n, p.len, p.wrap, p.start, p['end'], p.idx))
  local row = {}
  for i = 0, math.max(p.len, 1) - 1 do
    row[#row + 1] = ('%d%s'):format(p.val[i], i == p.idx and '*' or '')
  end
  print('  ' .. table.concat(row, ' '))
end

local function load_scene(path)
  local fresh = st.SceneState.new(os.time() & 0x7fff)
  local t, g, warnings = scene.read_file(path, fresh)
  if not t then print('!! ' .. g) return end
  ss, text, grid = fresh, t, g
  for _, warn in ipairs(warnings) do print('!! ' .. warn) end
  print(('loaded %s (%d warnings)'):format(path, #warnings))
end

-- ------------------------------------------------------------------- commands

local commands = {}

for n = 1, 8 do
  commands[tostring(n)] = function() exec.run_script(ss, n - 1) end
end
commands.m = function() exec.run_script(ss, st.METRO_SCRIPT) end
commands.i = function() exec.run_script(ss, st.INIT_SCRIPT) end

commands.e = function(rest)
  local n = tonumber(rest)
  if n and n >= 1 and n <= 10 then current_script = n - 1 end
  print(('editing script #%s'):format(script_label(current_script)))
end

commands.s = function(rest)
  local n, body = rest:match('^(%d+)%s*(.*)$')
  if not n then print('!! usage: .s <line> <command>') return end
  local cmd, err = compile(body)
  if not cmd then print('!! ' .. err) return end
  ss:overwrite_script_command(current_script, tonumber(n) - 1, cmd)
  show_script(current_script)
end

commands.p = function(rest)
  local n = tonumber(rest)
  show_script(n and (n - 1) or current_script)
end

commands.t = function(rest)
  local ms = tonumber(rest) or 10
  io_impl.ticks = io_impl.ticks + ms
  exec.tick(ss, ms)
end

commands.v = show_vars
commands.pat = function(rest) show_pattern(tonumber(rest) or ss.variables.p_n) end
commands.load = load_scene
commands.save = function(rest)
  local ok, err = scene.write_file(rest, ss, text, grid)
  print(ok and ('wrote ' .. rest) or ('!! ' .. err))
end

-- ---------------------------------------------------------------------- main

if arg[1] then load_scene(arg[1]) end

print('teletype. `.q` to quit, `.` commands listed in lib/tools/repl.lua')
while true do
  io.write(('#%s> '):format(script_label(current_script)))
  io.flush()
  local line = io.read('l')
  if line == nil or line == '.q' then break end

  if line:sub(1, 1) == '.' then
    local name, rest = line:match('^%.(%S*)%s*(.*)$')
    local fn = commands[(name or ''):lower()]
    if fn then fn(rest) else print('!! unknown command: .' .. tostring(name)) end
  elseif line ~= '' then
    local cmd, err = compile(line)
    if not cmd then
      print('!! ' .. err)
    else
      local es = st.ExecState.new()
      es:push()
      local has_value, value = exec.process_command(ss, es, cmd)
      if has_value then print(value) end
    end
  end
end
