-- io/midi_io.lua -- CV and TR as MIDI.
--
-- Any of the eight destinations (CV 1-4, TR A-D) can be pointed at a MIDI
-- device instead of, or as well as, a crow output.
--
-- Three modes:
--   pitch  a CV destination sets the note number for its channel
--   gate   a TR destination plays that note -- high sends note-on, low sends
--          note-off. Pairing a CV in `pitch` mode with a TR in `gate` mode on
--          the same device and channel is how you get a playable voice.
--   cc     a CV destination sends a controller value, 0..127
--
-- Note-on is deliberately driven by the gate rather than by the pitch write,
-- because that is the order a Teletype scene uses: set CV, then pulse TR.

local M = {}

M.OFF, M.PITCH, M.GATE, M.CC = 'off', 'pitch', 'gate', 'cc'

--- one entry per destination, keyed 'cv1'..'cv4' and 'trA'..'trD'
M.routes = {}

--- connected devices, keyed by port number
M.devices = {}

--- the note currently held per (port, channel), so gate-off can release it
local held = {}

--- last pitch written per (port, channel), used when a gate goes high
local pitch = {}

local function key(port, ch) return port .. ':' .. ch end

--- teletype's 0..16383 CV domain is 0..10V; a semitone is 1638.4/12
local function raw_to_note(raw)
  local n = math.floor(raw / (1638.4 / 12) + 0.5)
  if n < 0 then n = 0 elseif n > 127 then n = 127 end
  return n
end

local function raw_to_cc(raw)
  local v = math.floor(raw * 127 / 16383 + 0.5)
  if v < 0 then v = 0 elseif v > 127 then v = 127 end
  return v
end

function M.set_route(dest, route) M.routes[dest] = route end
function M.clear_routes() M.routes = {} end

--- attach a connected midi device for `port`
function M.set_device(port, dev) M.devices[port] = dev end

--- a CV destination changed. dest is 'cv1'..'cv4'.
function M.cv(dest, raw)
  local r = M.routes[dest]
  if not r or r.mode == M.OFF then return end
  local dev = M.devices[r.port]
  if not dev then return end

  if r.mode == M.PITCH then
    -- remembered for whichever gate plays it next; no note is sent here
    pitch[key(r.port, r.channel)] = raw_to_note(raw)
  elseif r.mode == M.CC then
    dev:cc(r.cc, raw_to_cc(raw), r.channel)
  end
end

--- a TR destination changed. dest is 'trA'..'trD'.
function M.tr(dest, state)
  local r = M.routes[dest]
  if not r or r.mode ~= M.GATE then return end
  local dev = M.devices[r.port]
  if not dev then return end

  local k = key(r.port, r.channel)
  if state ~= 0 then
    -- retrigger cleanly if the previous note is still held
    if held[k] then dev:note_off(held[k], 0, r.channel) end
    local note = pitch[k] or 60
    dev:note_on(note, r.velocity or 100, r.channel)
    held[k] = note
  elseif held[k] then
    dev:note_off(held[k], 0, r.channel)
    held[k] = nil
  end
end

--- release everything; used by KILL and on teardown
function M.all_off()
  for k, note in pairs(held) do
    local port, ch = k:match('^(%d+):(%d+)$')
    local dev = M.devices[tonumber(port)]
    if dev then dev:note_off(note, 0, tonumber(ch)) end
  end
  held = {}
end

return M
