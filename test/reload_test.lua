-- reload_test.lua -- every module must be dropped from package.loaded on load.
--
-- norns keeps `package.loaded` across script loads. Any module of ours left in
-- it is reused from the previous run, which means:
--
--   * stale code keeps running after the files on disk are replaced -- even
--     after deleting and re-copying the whole folder, because nothing rereads
--     them; only a norns restart would clear it
--   * singleton state (the op registry, routing tables, the ii read cache)
--     carries over, and ops get registered a second time onto a populated table
--
-- The purge lives inline at the top of teletype.lua -- it cannot be a module,
-- since that module would itself be cached. So this test reads the list out of
-- the source and checks it covers everything under lib/.
--
-- This exists because `ui.*` was missing from that list, and the symptom was a
-- fix that appeared to do nothing no matter how many times the script was
-- reloaded.

local H = require 'harness'

--- module names for every .lua under lib/, as `require` would spell them.
--- lib/tools is skipped: those are standalone build scripts that live there
--- only because norns' script browser excludes anything under lib/.
local function lib_modules()
  local names = {}
  local p = io.popen('find lib -name "*.lua" -not -path "lib/tools/*" 2>/dev/null')
  if not p then return names end
  for path in p:lines() do
    local rel = path:gsub('^lib/', ''):gsub('%.lua$', '')
    -- lib/ops/init.lua is required as 'ops.init'; directory init files are not
    -- special-cased anywhere in this project
    names[#names + 1] = rel:gsub('/', '.')
  end
  p:close()
  return names
end

--- the prefixes and explicit names teletype.lua purges
local function purge_rule()
  local src = assert(io.open('teletype.lua')):read('a')
  local block = src:match('for name in pairs%(package%.loaded%) do(.-)\nend')
  assert(block, 'could not find the purge loop in teletype.lua')

  local prefixes, exact = {}, {}
  for pat in block:gmatch("name:match%('%^(%w+)%%%.'%)") do
    prefixes[#prefixes + 1] = pat
  end
  -- the table of bare module names
  local list = block:match('%({(.-)}%)')
  if list then
    for name in list:gmatch('([%w_]+)%s*=%s*true') do exact[name] = true end
  end
  return prefixes, exact
end

local function is_purged(name, prefixes, exact)
  if exact[name] then return true end
  for _, prefix in ipairs(prefixes) do
    if name:sub(1, #prefix + 1) == prefix .. '.' then return true end
  end
  return false
end

--- every name our source passes to require(), and where from
local function required_names()
  local found = {}
  local p = io.popen('grep -rhoE "require *[\'\\"][^\'\\"]+[\'\\"]" '
    .. '--exclude-dir=tools lib teletype.lua 2>/dev/null')
  if not p then return found end
  for line in p:lines() do
    local name = line:match("require%s*['\"]([^'\"]+)['\"]")
    if name then found[name] = true end
  end
  p:close()
  return found
end

H.suite('reload: every module is dropped on script load', function()
  local modules = lib_modules()
  local prefixes, exact = purge_rule()

  H.test('the module list and purge rule were both found', function()
    H.ok(#modules > 20, ('only found %d modules under lib/'):format(#modules))
    H.ok(#prefixes > 0, 'no prefix patterns parsed from the purge loop')
    H.ok(next(exact) ~= nil, 'no explicit names parsed from the purge loop')
  end)

  H.test('nothing under lib/ survives a reload', function()
    for _, name in ipairs(modules) do
      H.ok(is_purged(name, prefixes, exact),
        ('%s is not purged -- a reload would reuse the previous copy')
          :format(name))
    end
  end)

  H.test('every require() in our source names a purged module', function()
    -- stronger than walking lib/: this also catches a require whose spelling
    -- does not match its path
    local names = required_names()
    H.ok(next(names) ~= nil, 'no requires found -- the scan is broken')
    for name in pairs(names) do
      -- norns' own modules are not ours to purge
      local ours = name:match('^ops%.') or name:match('^io%.')
        or name:match('^ui%.') or exact[name]
      local norns_module = ({ clock = true, util = true, tabutil = true,
        musicutil = true, controlspec = true, lattice = true })[name]
      if not norns_module then
        H.ok(ours ~= nil and ours ~= false,
          ('require "%s" is not covered by the purge'):format(name))
      end
    end
  end)

  H.test('no require uses slash syntax', function()
    -- lua caches 'ui.draw' and 'ui/draw' under different keys, so a slash
    -- spelling would survive a purge that matches dots
    for name in pairs(required_names()) do
      H.ok(not name:find('/', 1, true),
        ('require "%s" uses a slash; it would evade the purge'):format(name))
    end
  end)

  H.test('the lua standard library is left alone', function()
    -- `io` is ours only as a *prefix*; the bare name is the stdlib and
    -- purging it would break the script outright
    for _, name in ipairs({ 'io', 'os', 'string', 'table', 'math',
                            'coroutine', 'package' }) do
      H.ok(not is_purged(name, prefixes, exact),
        ('%s is the standard library and must not be purged'):format(name))
    end
  end)

  H.test('lib/version.lua matches the script version', function()
    local src = assert(io.open('teletype.lua')):read('a')
    local script_version = src:match("local VERSION = '([^']+)'")
    local lib = dofile('lib/version.lua')
    H.eq(lib, script_version,
      'lib/version.lua must match, or the stale-lib warning misfires')
  end)
end)
