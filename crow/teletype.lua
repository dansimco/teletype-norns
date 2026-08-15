-- teletype companion script for crow
--
-- Uploaded by the norns script at startup with norns.crow.loadscript(), NOT
-- written to flash -- crow keeps whatever script you had once it reboots.
--
-- Why this exists: every norns->crow message is an ASCII string over serial,
-- so a TR pulse done from norns would cost two round trips and land with the
-- jitter of the norns event queue. Here the pulse width, polarity and slew
-- live on the crow, and firing a trigger is a single short call whose timing
-- is resolved by crow's own scheduler.
--
-- norns owns the routing: it decides that "CV 1" means output 3 and calls
-- tt_cv(3, volts). crow only needs to know whether an output is a pitch or a
-- gate, so it can hold the right slew.

-- per-output state. crow cannot be queried from norns, so anything we need to
-- read back later has to be mirrored here as well as on the norns side.
local role = { 'cv', 'cv', 'tr', 'tr' }   -- 'cv' | 'tr' | 'off'
local slew = { 0, 0, 0, 0 }               -- seconds
local offset = { 0, 0, 0, 0 }             -- volts
local level = { 0, 0, 0, 0 }              -- volts, before offset
local width = { 0.1, 0.1, 0.1, 0.1 }      -- pulse width, seconds
local polarity = { 1, 1, 1, 1 }
local gate_high = 5                       -- volts

--- the levels a gate rests at and pulses to, given its polarity.
-- Teletype's TR.POL inverts the whole gate: with polarity 0 the output rests
-- HIGH and pulses momentarily low. That is why this is spelled out rather
-- than handed to crow's `pulse(time, level, polarity)` -- the resting level
-- has to change too, not just the direction.
local function levels(n)
  if polarity[n] ~= 0 then
    return gate_high, 0      -- active, rest
  end
  return 0, gate_high
end

--- an output configured as a gate must not slew, or the pulse smears
local function apply_role(n)
  if role[n] == 'tr' then
    output[n].slew = 0
    local _, rest = levels(n)
    output[n].volts = rest
  else
    output[n].slew = slew[n]
  end
end

-- ------------------------------------------------------------------ routing

function tt_map(n, r)
  role[n] = r
  apply_role(n)
end

function tt_gate_level(v)
  gate_high = v
  for n = 1, 4 do if role[n] == 'tr' then apply_role(n) end end
end

-- ----------------------------------------------------------------------- CV

function tt_cv(n, v)
  level[n] = v
  output[n].volts = v + offset[n]
end

--- CV.SET: write without slewing, then restore the slew time
function tt_cv_set(n, v)
  level[n] = v
  output[n].slew = 0
  output[n].volts = v + offset[n]
  output[n].slew = slew[n]
end

function tt_slew(n, seconds)
  slew[n] = seconds
  if role[n] ~= 'tr' then output[n].slew = seconds end
end

--- CV.OFF: an offset added at the output stage, applied immediately
function tt_offset(n, v)
  offset[n] = v
  output[n].volts = level[n] + v
end

-- ----------------------------------------------------------------------- TR

function tt_tr(n, state)
  output[n].volts = (state ~= 0) and gate_high or 0
end

--- Fire a pulse.
--
-- The action is built here, at fire time, rather than armed once in advance.
-- It has to be: Teletype's TR.PULSE sets the output high *and then* asks for
-- the pulse, and on crow writing `output[n].volts` replaces whatever action
-- the channel was holding. A pre-armed pulse would be overwritten by that
-- write, and `output[n]()` would simply re-run "go high" -- leaving the gate
-- stuck high instead of pulsing.
--
-- This is still one short message from norns; the shape of the envelope and
-- its timing are resolved here.
function tt_pulse(n)
  local active, rest = levels(n)
  output[n].action = { to(active, 0), to(active, width[n]), to(rest, 0) }
  output[n]()
end

function tt_time(n, seconds)
  width[n] = seconds
end

function tt_pol(n, p)
  polarity[n] = p
  -- the resting level changes with polarity, so settle the output there now
  if role[n] == 'tr' then apply_role(n) end
end

--- clear everything: used by KILL and on teardown
function tt_reset()
  for n = 1, 4 do
    level[n], offset[n] = 0, 0
    output[n].slew = 0
    output[n].volts = 0
    output[n].slew = slew[n]
  end
end

for n = 1, 4 do apply_role(n) end
