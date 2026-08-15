-- gen_help.lua
--
-- Builds lib/ops/help.lua from teletype/docs/ops/*.toml: one prototype and
-- one-line summary per op, for the in-app help mode.
--
-- Hand-writing 429 help strings would be both tedious and a second source of
-- truth that drifts from the reference. This reads the same TOML that
-- generates the official documentation.
--
-- A small TOML subset is enough here: `[SECTION]` headers and `key = "value"`
-- with plain, triple-quoted, or multi-line triple-quoted strings.
--
-- usage: lua5.4 lib/tools/gen_help.lua

local DOCS = '../teletype/docs/ops'
local OUT = 'lib/ops/help.lua'

local manifest = dofile('lib/ops/manifest.lua')

--- ops we actually implement; help for anything else would be misleading
local in_scope = {}
for _, o in ipairs(manifest.ops) do
  if manifest.in_scope[o[5]] then in_scope[o[1]] = true end
end
for _, m in ipairs(manifest.mods) do
  if manifest.in_scope[m[3]] then in_scope[m[1]] = true end
end

--- strip the markdown the docs use for emphasis and code spans
local function clean(s)
  s = s:gsub('%s+', ' ')
  s = s:gsub('`([^`]*)`', '%1')
  s = s:gsub('%*%*([^%*]*)%*%*', '%1')
  s = s:gsub('%*([^%*]*)%*', '%1')
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local entries = {}

local function parse_file(path)
  local f = io.open(path)
  if not f then return end
  local section
  local pending_key, pending    -- accumulating a triple-quoted string

  for line in f:lines() do
    if pending_key then
      local close = line:find('"""', 1, true)
      if close then
        pending[#pending + 1] = line:sub(1, close - 1)
        entries[section] = entries[section] or {}
        entries[section][pending_key] = clean(table.concat(pending, ' '))
        pending_key, pending = nil, nil
      else
        pending[#pending + 1] = line
      end
    else
      local header = line:match('^%s*%[([^%]]+)%]%s*$')
      if header then
        -- most files quote the section name (["CV.OFF"]) but some do not
        -- ([A]); either way the op name is what is inside
        section = header:match('^"(.*)"$') or header
        entries[section] = entries[section] or {}
      elseif section then
        -- key = """...""" all on one line
        local k, v = line:match('^%s*([%w_]+)%s*=%s*"""(.-)"""%s*$')
        if k then
          entries[section][k] = clean(v)
        else
          -- key = """ opening a multi-line string
          k = line:match('^%s*([%w_]+)%s*=%s*"""%s*$')
          if k then
            pending_key, pending = k, {}
          else
            -- aliases = ["+", "PLUS"]
            local list = line:match('^%s*aliases%s*=%s*%[(.-)%]%s*$')
            if list then
              local names = {}
              for a in list:gmatch('"(.-)"') do names[#names + 1] = a end
              entries[section].aliases = names
            else
              k, v = line:match('^%s*([%w_]+)%s*=%s*"(.-)"%s*$')
              if k then entries[section][k] = clean(v) end
            end
          end
        end
      end
    end
  end
  f:close()
end

local p = io.popen('ls ' .. DOCS .. '/*.toml 2>/dev/null')
local files = 0
for path in p:lines() do
  parse_file(path)
  files = files + 1
end
p:close()
assert(files > 0, 'no op docs found at ' .. DOCS)

-- ------------------------------------------------------------------- emit

-- an alias shares its target's documentation, and there are 49 of them (+, -,
-- TR.P, PRM, EV...). Without this they would show no help at all, which for
-- something like `+` is exactly the op a newcomer looks up first.
for name, e in pairs(entries) do
  if type(e) == 'table' and e.aliases then
    for _, alias in ipairs(e.aliases) do
      if not entries[alias] then
        -- swap the leading op name for the alias by slicing, not gsub: several
        -- aliases are punctuation (%, +, *) and would be read as patterns or
        -- as capture references in a replacement string
        local function retitle(proto)
          if not proto then return nil end
          if proto:sub(1, #name) == name then
            return alias .. proto:sub(#name + 1)
          end
          return proto
        end
        entries[alias] = {
          prototype = retitle(e.prototype) or alias,
          prototype_set = retitle(e.prototype_set),
          short = e.short,
          alias_of = name,
        }
      end
    end
  end
end

local names = {}
for name in pairs(entries) do
  if in_scope[name] then names[#names + 1] = name end
end
table.sort(names)

local out = {}
local function emit(s) out[#out + 1] = s end

emit([[
-- help.lua -- GENERATED, do not edit by hand.
--
-- One prototype and one-line summary per implemented op, extracted from
-- teletype/docs/ops/*.toml -- the same source the official documentation is
-- built from, so the help cannot drift from the reference.
--
-- regenerate with: lua5.4 lib/tools/gen_help.lua

local M = {}

-- name -> { prototype, set prototype or nil, summary, alias of (optional) }
M.ops = {]])

local documented = 0
for _, name in ipairs(names) do
  local e = entries[name]
  local proto = e.prototype or name
  local proto_set = e.prototype_set
  local short = e.short or e.description or ''
  if short ~= '' then documented = documented + 1 end
  emit(('  [%q] = { %q, %s, %q%s },'):format(
    name, proto, proto_set and ('%q'):format(proto_set) or 'nil', short,
    e.alias_of and (', %q'):format(e.alias_of) or ''))
end

emit('}')
emit('')
emit([[
--- every documented op name, sorted, for browsing
M.names = {}
for name in pairs(M.ops) do M.names[#M.names + 1] = name end
table.sort(M.names)

--- look up help, or nil
function M.get(name) return M.ops[name] end

return M]])

local f = assert(io.open(OUT, 'w'))
f:write(table.concat(out, '\n'), '\n')
f:close()

print(('wrote %s: %d ops from %d files (%d with summaries)')
  :format(OUT, #names, files, documented))

-- report anything implemented but undocumented, so gaps are visible
local missing = {}
for name in pairs(in_scope) do
  if not entries[name] then missing[#missing + 1] = name end
end
table.sort(missing)
if #missing > 0 then
  print(('%d implemented ops have no doc entry:'):format(#missing))
  print('  ' .. table.concat(missing, ' '):sub(1, 300))
end
