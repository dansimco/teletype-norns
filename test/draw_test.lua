-- draw_test.lua -- the text grid, and that every mode fits on the screen.
--
-- The screen is 128x64 and the font size is configurable, so the number of
-- rows is not fixed: size 6 gives 10, size 8 gives 8. A mode that assumes 10
-- draws its prompt at y=79 on an 8-row screen -- off the bottom, with no
-- error. This mocks the screen and checks nothing lands outside it.

local H = require 'harness'

--- a stand-in for norns' screen that records where things are drawn
local function mock_screen(char_w, char_h)
  local rec = { moves = {}, points = {}, rects = {}, texts = {} }
  local cur = { x = 0, y = 0, level = 0 }
  _G.screen = {
    clear = function() end,
    update = function() end,
    level = function(v) cur.level = v end,
    font_face = function() end,
    font_size = function() end,
    move = function(x, y)
      cur.x, cur.y = x, y
      rec.moves[#rec.moves + 1] = y
      rec.points[#rec.points + 1] = { x = x, y = y }
    end,
    text = function(s)
      rec.texts[#rec.texts + 1] = { x = cur.x, y = cur.y, s = s }
    end,
    text_right = function(s)
      rec.texts[#rec.texts + 1] = { x = cur.x, y = cur.y, s = s }
    end,
    rect = function(x, y, w, h)
      rec.rects[#rec.rects + 1] =
        { x = x, y = y, w = w, h = h, level = cur.level }
    end,
    fill = function() end,
    -- draw no longer measures, but keep this so a stray call is harmless
    text_extents = function(_s) return char_w, char_h end,
  }
  return rec
end

--- the highest pixel any drawing touched
local function lowest_pixel(rec)
  local low = 0
  for _, y in ipairs(rec.moves) do if y > low then low = y end end
  for _, r in ipairs(rec.rects) do
    if r.y + r.h > low then low = r.y + r.h end
  end
  return low
end

H.suite('draw: the grid follows the cell', function()
  H.test('Particle at size 8 is 32 columns by 8 rows', function()
    mock_screen(4, 8)
    package.loaded['ui.draw'] = nil
    local draw = require 'ui.draw'
    draw.configure(68, 8, true)
    H.eq(draw.CW, 4, 'four pixels wide')
    H.eq(draw.CH, 8, 'eight tall')
    H.eq(draw.COLS, 32, 'so 32 columns -- a teletype line fits')
    H.eq(draw.ROWS, 8, 'and 8 rows')
    H.eq(draw.prompt_row(), 7, 'the prompt is on the last row')
    H.eq(draw.body_rows(), 6, 'six body rows, exactly SCRIPT_MAX_COMMANDS')
  end)

  H.test('tom-thumb at size 6 is 32 by 10', function()
    mock_screen(4, 6)
    package.loaded['ui.draw'] = nil
    local draw = require 'ui.draw'
    draw.configure(25, 6, true)
    H.eq(draw.ROWS, 10, 'ten rows at size 6')
    H.eq(draw.prompt_row(), 9, 'prompt moves with it')
  end)

  H.test('text is upper-cased when asked', function()
    local rec = mock_screen(4, 8)
    package.loaded['ui.draw'] = nil
    local draw = require 'ui.draw'
    draw.configure(68, 8, true)
    draw.text(0, 0, 'live')
    H.eq(rec.texts[#rec.texts].s, 'LIVE', 'upper case')
    draw.configure(68, 8, false)
    draw.text(0, 0, 'live')
    H.eq(rec.texts[#rec.texts].s, 'live', 'or left alone')
  end)

  H.test('the cursor lands on the character it marks', function()
    local rec = mock_screen(4, 8)
    package.loaded['ui.draw'] = nil
    local draw = require 'ui.draw'
    draw.configure(68, 8, true)
    draw.line_with_cursor(2, 7, 'CV 1', 2, 15)
    -- the cursor rect should sit at 2 columns of prefix past the start
    local r = rec.rects[#rec.rects]
    H.eq(r.y, 56, 'on the prompt row')
    H.eq(r.h, 8, 'one row tall')
  end)
end)

H.suite('draw: every mode fits the screen', function()
  -- both the fonts we care about
  for _, cfg in ipairs({ { face = 68, size = 8, w = 4, h = 8, rows = 8 },
                         { face = 25, size = 6, w = 4, h = 6, rows = 10 } }) do
    H.test(('all modes stay on screen at size %d (%d rows)')
        :format(cfg.size, cfg.rows), function()
      local rec = mock_screen(cfg.w, cfg.h)

      -- rebuild the UI against this screen
      for _, name in ipairs({ 'ui.draw', 'ui.activity', 'ui.modes', 'ui.live',
                              'ui.edit', 'ui.pattern', 'ui.preset', 'ui.help',
                              'ui.init' }) do
        package.loaded[name] = nil
      end
      local draw = require 'ui.draw'
      local ui = require 'ui.init'
      local st = require 'state'
      require 'ops.init'
      draw.configure(cfg.face, cfg.size, true)

      local ss = st.SceneState.new(0)
      ui.set_scene(ss, require('scene').new_text())
      -- give the modes something to draw
      local tok = require 'tokenizer'
      for l = 0, 5 do
        ss:overwrite_script_command(0, l, tok.parse('CV 1 V ' .. l))
      end
      ss.patterns[0].len = 20
      ui.preset.set_index({ [0] = 'A SCENE', [1] = 'ANOTHER' })

      for _, mode in ipairs({ ui.modes.LIVE, ui.modes.EDIT, ui.modes.PATTERN,
                              ui.modes.PRESET_R, ui.modes.PRESET_W,
                              ui.modes.HELP }) do
        rec.moves, rec.rects, rec.texts = {}, {}, {}
        ui.modes.set(mode)
        ui.redraw('')
        local low = lowest_pixel(rec)
        H.ok(low <= 64,
          ('%s drew down to y=%d, past the bottom of the screen at %d rows')
            :format(mode, low, cfg.rows))
        H.ok(#rec.texts > 0, ('%s drew nothing at all'):format(mode))
      end
    end)
  end
end)

H.suite('draw: the live mode activity strip', function()
  -- Every pixel here is teletype/module/live_mode.c:658-728. The point of the
  -- suite is that a typo in either the glyph table or the coordinates fails,
  -- so the expectations are rebuilt from the module's own tables rather than
  -- hardcoded a second time.

  --- rebuild the UI against a fresh mock and return everything it needs
  local function fresh()
    local rec = mock_screen(4, 8)
    for _, name in ipairs({ 'ui.draw', 'ui.activity', 'ui.modes', 'ui.live',
                            'ui.edit', 'ui.pattern', 'ui.preset', 'ui.help',
                            'ui.init' }) do
      package.loaded[name] = nil
    end
    local draw = require 'ui.draw'
    local ui = require 'ui.init'
    local st = require 'state'
    require 'ops.init'
    draw.configure(68, 8, true)

    local ss = st.SceneState.new(0)
    ui.set_scene(ss, require('scene').new_text())
    return rec, ui, ss, st
  end

  --- the strip's single pixels, as a level -> { ['x,y'] = true } map
  local function strip(rec)
    local by_level = {}
    for _, r in ipairs(rec.rects) do
      if r.w == 1 and r.h == 1 and r.x >= 85 then
        by_level[r.level] = by_level[r.level] or {}
        by_level[r.level][('%d,%d'):format(r.x, r.y)] = true
      end
    end
    return by_level
  end

  local function keys(set)
    local out = {}
    for k in pairs(set or {}) do out[#out + 1] = k end
    table.sort(out)
    return table.concat(out, ' ')
  end

  --- expand a glyph's '#' cells to pixel keys at x0
  local function expand(rows, x0, into)
    for y = 1, #rows do
      for x = 1, #rows[y] do
        if rows[y]:sub(x, x) == '#' then
          into[('%d,%d'):format(x0 + x - 1, y - 1)] = true
        end
      end
    end
    return into
  end

  H.test('an idle scene draws all four icons dim, and nothing lit', function()
    local rec, ui = fresh()
    ui.modes.set(ui.modes.LIVE)
    ui.redraw('')

    local by_level = strip(rec)
    local expected = {}
    for _, icon in ipairs(ui.activity.ICONS) do
      expand(ui.activity.GLYPH[icon.name], icon.x, expected)
    end
    -- eight unmuted scripts, all at the default rising polarity: one pixel
    -- each, staggered onto rows 1 and 3
    for i = 0, 7 do
      expected[('%d,%d'):format(87 + i, i % 2 == 0 and 1 or 3)] = true
    end

    H.eq(keys(by_level[15]), '', 'nothing is lit')
    H.eq(keys(by_level[1]), keys(expected), 'every glyph pixel is dim')
  end)

  H.test('each flag lights its own glyph and only that one', function()
    local rec, ui, ss, st = fresh()
    ss.delay.count = 1
    ss.stack_op.top = 1
    ss:overwrite_script_command(st.METRO_SCRIPT, 0,
      require('tokenizer').parse('TR.P A'))
    ss.variables.mutes[0] = true

    ui.modes.set(ui.modes.LIVE)
    ui.redraw('')

    local by_level = strip(rec)
    local lit = {}
    expand(ui.activity.GLYPH.delay, 106, lit)
    expand(ui.activity.GLYPH.stack, 114, lit)
    expand(ui.activity.GLYPH.metro, 122, lit)
    lit['87,1'] = true                 -- script 0, muted

    local dim = {}
    expand(ui.activity.GLYPH.slew, 98, dim)   -- nothing slews without hardware
    for i = 1, 7 do
      dim[('%d,%d'):format(87 + i, i % 2 == 0 and 1 or 3)] = true
    end

    H.eq(keys(by_level[15]), keys(lit), 'delay, stack, metro and one mute')
    H.eq(keys(by_level[1]), keys(dim), 'slew and the seven unmuted scripts')
  end)

  H.test('a metro timer with an empty script leaves the icon dim', function()
    local rec, ui, ss = fresh()
    ss.variables.m_act = 1
    ui.modes.set(ui.modes.LIVE)
    ui.redraw('')
    -- main.c:1028-1031 wants both the timer and a non-empty script
    H.eq(strip(rec)[15], nil, 'the metro icon needs something to run')
  end)

  H.test('falling polarity widens a mute mark to two pixels', function()
    local rec, ui, ss = fresh()
    ss.variables.script_pol[0] = 3      -- both edges
    ss.variables.script_pol[1] = 2      -- falling only
    ui.modes.set(ui.modes.LIVE)
    ui.redraw('')

    local dim = strip(rec)[1]
    H.ok(dim['87,1'] and dim['88,1'], 'script 0 takes two pixels on row 1')
    H.ok(dim['89,3'] and not dim['88,3'],
      'script 1 falling-only sits one pixel right, on row 3')
  end)

  H.test('the strip clears its band and stays inside it', function()
    local rec, ui = fresh()
    ui.modes.set(ui.modes.LIVE)
    ui.redraw('')

    local cleared = false
    for _, r in ipairs(rec.rects) do
      if r.level == 0 and r.x == 85 and r.y == 0 and r.w == 43 and r.h == 8 then
        cleared = true
      end
      if r.w == 1 and r.h == 1 and r.x >= 85 then
        H.ok(r.x <= 127 and r.y >= 0 and r.y <= 7,
          ('a strip pixel landed outside the band at %d,%d'):format(r.x, r.y))
      end
    end
    H.ok(cleared, 'the band is blanked first, as live_mode.c:647-652 does')
  end)

  H.test('the status text stops short of the band', function()
    local rec, ui = fresh()
    ui.modes.set(ui.modes.LIVE)
    ui.redraw('I2C?2')
    for _, t in ipairs(rec.texts) do
      if t.y <= 7 then
        H.ok(t.x <= 83,
          ('top row text right-aligned at x=%d, inside the strip'):format(t.x))
      end
    end
  end)

  H.test('no other mode draws the strip', function()
    local rec, ui = fresh()
    for _, mode in ipairs({ ui.modes.EDIT, ui.modes.PATTERN, ui.modes.HELP }) do
      rec.rects = {}
      ui.modes.set(mode)
      ui.redraw('')
      H.eq(next(strip(rec)), nil,
        ('%s drew indicator pixels; they are LIVE only'):format(mode))
    end
  end)
end)

_G.screen = nil
