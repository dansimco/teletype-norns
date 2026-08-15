-- io/crow_io.lua -- crow's four outputs.
--
-- Normally this drives the companion script in crow/teletype.lua, so pulse
-- and slew timing is resolved on the crow rather than over serial. If that
-- upload fails -- an older firmware, a crow that is busy, a user who would
-- rather not have their script replaced -- everything still works through the
-- stock crow API, just with the timing done from norns. `M.mode` says which
-- path is live so the UI can show it.

local M = {}

M.OFF, M.CV, M.TR = 'off', 'cv', 'tr'

--- how each crow output is used: role plus which teletype destination it is.
-- index is the crow output 1..4.
M.outputs = {
  { role = M.CV, index = 1 },
  { role = M.CV, index = 2 },
  { role = M.TR, index = 1 },
  { role = M.TR, index = 2 },
}

-- reverse lookups, rebuilt by M.apply_routing
M.cv_out = {}     -- teletype CV index (0-based) -> crow output
M.tr_out = {}     -- teletype TR index (0-based) -> crow output

M.mode = 'companion'    -- 'companion' | 'stock' | 'absent'
M.gate_level = 5        -- volts a gate goes to

-- mirrored state, because crow cannot be read back
local width = { 0.1, 0.1, 0.1, 0.1 }
local polarity = { 1, 1, 1, 1 }

--- the norns `crow` global, injected so this module stays testable
M.crow = nil

local function send(fmt, ...)
  if M.crow then M.crow.send(fmt:format(...)) end
end

-- ------------------------------------------------------------------ routing

--- rebuild the destination -> output lookups from M.outputs
function M.apply_routing()
  M.cv_out, M.tr_out = {}, {}
  for out = 1, 4 do
    local o = M.outputs[out]
    if o.role == M.CV then
      M.cv_out[o.index - 1] = out       -- ops address CV 0..3 internally
    elseif o.role == M.TR then
      M.tr_out[o.index - 1] = out
    end
  end
  if M.mode == 'companion' then
    for out = 1, 4 do
      send('tt_map(%d,%q)', out, M.outputs[out].role)
    end
    send('tt_gate_level(%g)', M.gate_level)
  elseif M.mode == 'stock' and M.crow then
    for out = 1, 4 do
      if M.outputs[out].role == M.TR then
        M.crow.output[out].slew = 0
      end
    end
  end
end

-- --------------------------------------------------------------------- CV
-- Teletype's CV domain is 0..16383 spanning 0..10V.

local function to_volts(raw) return raw / 1638.4 end

function M.cv(i, raw, slewed)
  local out = M.cv_out[i]
  if not out then return end
  if M.mode == 'companion' then
    send(slewed ~= 0 and 'tt_cv(%d,%.4f)' or 'tt_cv_set(%d,%.4f)',
      out, to_volts(raw))
  elseif M.crow then
    -- stock path: CV.SET has to zero the slew by hand
    if slewed == 0 then M.crow.output[out].slew = 0 end
    M.crow.output[out].volts = to_volts(raw)
    if slewed == 0 then M.crow.output[out].slew = M.slew_seconds or 0 end
  end
end

function M.cv_slew(i, ms)
  local out = M.cv_out[i]
  if not out then return end
  local seconds = ms / 1000
  if M.mode == 'companion' then
    send('tt_slew(%d,%.4f)', out, seconds)
  elseif M.crow then
    M.crow.output[out].slew = seconds
  end
end

function M.cv_off(i, raw)
  local out = M.cv_out[i]
  if not out then return end
  if M.mode == 'companion' then
    send('tt_offset(%d,%.4f)', out, to_volts(raw))
  end
  -- the stock path has nowhere to hold an offset; the core already folds it
  -- into the value it passes to cv(), so nothing more to do here
end

-- --------------------------------------------------------------------- TR

function M.tr(i, state)
  local out = M.tr_out[i]
  if not out then return end
  if M.mode == 'companion' then
    send('tt_tr(%d,%d)', out, state ~= 0 and 1 or 0)
  elseif M.crow then
    M.crow.output[out].volts = (state ~= 0) and M.gate_level or 0
  end
end

function M.tr_pulse(i, ms)
  local out = M.tr_out[i]
  if not out then return end
  if M.mode == 'companion' then
    -- width and polarity already live on the crow; this is one short message
    send('tt_pulse(%d)', out)
  elseif M.crow then
    M.crow.output[out].action =
      ('pulse(%.4f,%g,%d)'):format(width[out], M.gate_level, polarity[out])
    M.crow.output[out]()
  end
end

function M.tr_pulse_time(i, ms)
  local out = M.tr_out[i]
  if not out then return end
  width[out] = ms / 1000
  if M.mode == 'companion' then
    send('tt_time(%d,%.4f)', out, width[out])
  end
end

function M.tr_pol(i, p)
  local out = M.tr_out[i]
  if not out then return end
  polarity[out] = (p ~= 0) and 1 or 0
  if M.mode == 'companion' then
    send('tt_pol(%d,%d)', out, polarity[out])
  end
end

function M.reset()
  if M.mode == 'companion' then
    send('tt_reset()')
  elseif M.crow then
    for out = 1, 4 do M.crow.output[out].volts = 0 end
  end
end

-- ------------------------------------------------------------------ startup

--- upload the companion script, falling back to the stock API if it fails.
-- `on_ready` runs once the mode is settled.
--
-- NOTE the connectivity check goes through `norns.crow.connected()`, not
-- `crow.connected()`. The `crow` global is a write-only proxy: any field it
-- does not itself define is turned into a *remote* call, so `crow.connected()`
-- would ship the string "connected()" to the module and fail there. Only
-- version/identity/reset/kill/clear/send/public are real local functions.
function M.connect(crow, on_ready)
  M.crow = crow
  local present = crow ~= nil
    and norns ~= nil and norns.crow ~= nil
    and norns.crow.connected ~= nil and norns.crow.connected()

  if not present then
    M.mode = 'absent'
    if on_ready then on_ready(M.mode) end
    return
  end

  -- returns the upload coroutine so the caller can cancel it if the script
  -- is unloaded before the upload finishes
  local ok, handle = pcall(function()
    return norns.crow.loadscript('teletype.lua', false, function()
      M.mode = 'companion'
      M.apply_routing()
      if on_ready then on_ready(M.mode) end
    end)
  end)

  if ok then return handle end

  print('teletype: crow companion upload failed, using the stock API')
  M.mode = 'stock'
  M.apply_routing()
  if on_ready then on_ready(M.mode) end
  return nil
end

return M
