-- process_test.lua
--
-- Executes test/fixtures/process_corpus.txt against a single persistent scene
-- and diffs both the per-line result and the final scene state against the C
-- oracle.
--
-- fixture records (lib/tools/oracle/oracle.c mode_process):
--   run  <input> <has_value> <value> <io log>
--   err  <input> <err> <msg>
--   tick <ms> <io log>
--   var/cv/tr/pat/patv/q  <key> <value>     -- final state snapshot

local H = require 'harness'
local exec = require 'exec'
local st = require 'state'
local tokenizer = require 'tokenizer'
local validate = require 'validate'
local log_io = require 'log_io'
require 'ops.init'

-- record io calls so the output side (CV/TR, and the i2c packets that indices
-- 5..20 generate) is compared against the oracle too
exec.set_io(log_io)

H.suite('process: lua vs teletype C oracle', function()
  local records = H.fixture('test/fixtures/process.tsv')

  -- run the whole corpus once and keep both the per-line results and the
  -- final state, so the two tests below don't have to re-execute it
  local ss = st.SceneState.new(0)
  local results = {}

  -- parse + validate a line the way every caller does
  local function compile(input)
    local cmd, perr = tokenizer.parse(input:upper())
    if perr ~= 'E_OK' then return nil, perr end
    local verr = validate.validate(cmd)
    if verr ~= 'E_OK' then return nil, verr end
    return cmd
  end

  for _, line in ipairs(records) do
    local f = H.split_tsv(line)
    if f[1] == 'run' or f[1] == 'err' then
      local input = f[2]
      local cmd, err = compile(input)
      if cmd then
        local es = st.ExecState.new()
        es:push()
        log_io.reset()
        local has_value, value = exec.process_command(ss, es, cmd)
        results[#results + 1] = { kind = 'run', input = input,
                                  has_value = has_value, value = value,
                                  io = log_io.text() }
      else
        results[#results + 1] = { kind = 'err', input = input, err = err }
      end
    elseif f[1] == 'script' then
      local n, l = f[2]:match('(%d+),(%d+)')
      local cmd = compile(f[3])
      if cmd then
        ss:overwrite_script_command(tonumber(n), tonumber(l), cmd)
      end
      results[#results + 1] = { kind = 'script' }
    elseif f[1] == 'clear' then
      ss:clear_script(tonumber(f[2]))
      results[#results + 1] = { kind = 'clear' }
    elseif f[1] == 'runscript' then
      exec.run_script(ss, tonumber(f[2]))
      results[#results + 1] = { kind = 'runscript' }
    elseif f[1] == 'tick' then
      exec.tick(ss, tonumber(f[2]))
      results[#results + 1] = { kind = 'tick' }
    end
  end

  H.test('corpus is non-trivial', function()
    H.ok(#results > 1000, ('only %d executed records'):format(#results))
  end)

  H.test('per-line results match', function()
    local i = 0
    for _, line in ipairs(records) do
      local f = H.split_tsv(line)
      if f[1] == 'run' then
        i = i + 1
        local got = results[i]
        if H.eq(got.kind, 'run', ('kind for %q'):format(f[2])) then
          local want_has = f[3] == '1'
          H.eq(got.has_value, want_has, ('has_value for %q'):format(f[2]))
          if want_has and got.has_value then
            H.eq(got.value, tonumber(f[4]), ('value of %q'):format(f[2]))
          end
          H.eq(got.io, f[5] or '', ('io calls for %q'):format(f[2]))
        end
      elseif f[1] == 'err' or f[1] == 'tick' or f[1] == 'script'
          or f[1] == 'clear' or f[1] == 'runscript' then
        -- these advance the shared cursor but carry no comparable result
        i = i + 1
      end
    end
  end)

  H.test('final scene state matches', function()
    -- map the oracle's state keys onto our scene
    local VARS = {
      A = 'a', B = 'b', C = 'c', D = 'd', X = 'x', Y = 'y', Z = 'z', T = 't',
      O = 'o', DRUNK = 'drunk', Q_N = 'q_n', P_N = 'p_n', M = 'm',
    }
    for _, line in ipairs(records) do
      local f = H.split_tsv(line)
      if f[1] == 'var' then
        local field = VARS[f[2]]
        if field then
          H.eq(ss.variables[field], tonumber(f[3]),
            ('variable %s'):format(f[2]))
        end
      elseif f[1] == 'cv' then
        H.eq(ss.variables.cv[tonumber(f[2])], tonumber(f[3]),
          ('cv %s'):format(f[2]))
      elseif f[1] == 'tr' then
        H.eq(ss.variables.tr[tonumber(f[2])], tonumber(f[3]),
          ('tr %s'):format(f[2]))
      elseif f[1] == 'patv' then
        local p, i = f[2]:match('(%d+),(%d+)')
        H.eq(ss.patterns[tonumber(p)].val[tonumber(i)], tonumber(f[3]),
          ('pattern %s'):format(f[2]))
      elseif f[1] == 'q' then
        H.eq(ss.variables.q[tonumber(f[2])], tonumber(f[3]),
          ('queue %s'):format(f[2]))
      end
    end
  end)
end)
