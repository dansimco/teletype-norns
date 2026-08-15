-- draw_test.lua -- the bitmap font, and that every mode fits on the screen.
--
-- ui/draw renders Teletype's own font into a 128x64 byte buffer and hands it
-- to screen.poke, so these tests read that buffer directly: they assert on the
-- pixels that would reach the screen rather than on the calls that produced
-- them. That makes the font checks exact -- a glyph is compared against the
-- bits in teletype/libavr32/src/font.c -- and it means a mode laying itself
-- out from the wrong row count is caught by draw.overflow rather than by
-- guessing from move() coordinates.

local H = require 'harness'

--- a stand-in for norns' screen. Only poke and update are used now.
local function mock_screen()
  local rec = { poked = nil }
  _G.screen = {
    update = function() end,
    poke = function(_x, _y, _w, _h, s) rec.poked = s end,
    -- the renderer touches nothing else, but a stray call should not error
    clear = function() end,
    level = function() end,
    font_face = function() end,
    font_size = function() end,
    move = function() end,
    text = function() end,
    text_right = function() end,
    rect = function() end,
    fill = function() end,
    text_extents = function() return 4, 8 end,
  }
  return rec
end

--- reload the UI against a fresh mock, and hand back what a test needs
local function fresh()
  local rec = mock_screen()
  for _, name in ipairs({ 'ui.font', 'ui.draw', 'ui.activity', 'ui.modes',
                          'ui.live', 'ui.edit', 'ui.pattern', 'ui.preset',
                          'ui.help', 'ui.init' }) do
    package.loaded[name] = nil
  end
  local draw = require 'ui.draw'
  local ui = require 'ui.init'
  local st = require 'state'
  require 'ops.init'
  return rec, draw, ui, st
end

--- the level at a pixel, from the live buffer
local function px(draw, x, y)
  local buf, w = draw.buffer()
  return buf[y * w + x + 1]
end

--- a rectangle of the buffer as text, for legible failures.
-- '#' is full brightness, '+' anything else lit, '.' dark.
local function art(draw, x0, y0, w, h)
  local rows = {}
  for y = y0, y0 + h - 1 do
    local line = {}
    for x = x0, x0 + w - 1 do
      local v = px(draw, x, y)
      line[#line + 1] = v == 0 and '.' or (v == 15 and '#' or '+')
    end
    rows[#rows + 1] = table.concat(line)
  end
  return table.concat(rows, '\n')
end

H.suite('draw: the font is the hardware\'s', function()
  H.test('the screen is 32 columns by 8 rows, fixed', function()
    local _, draw = fresh()
    H.eq(draw.CH, 8, 'the glyph box is eight tall')
    H.eq(draw.ROWS, 8, 'so eight rows, as on the module')
    H.eq(draw.COLS, 32, 'and 32 tab stops -- a teletype line fits')
    H.eq(draw.prompt_row(), 7, 'the prompt is on the last row')
    H.eq(draw.body_rows(), 6, 'six body rows, exactly SCRIPT_MAX_COMMANDS')
  end)

  H.test('advances come from font_string_pixels, not a flat cell', function()
    local _, draw = fresh()
    -- (6 - first - last) + 1, read straight off font.c
    local expect = {
      A = 4, B = 4, C = 4, I = 4, J = 3, M = 6, N = 5, O = 4, W = 6, X = 4,
      ['0'] = 4, ['1'] = 4, [' '] = 4, ['.'] = 2, [':'] = 2, ['-'] = 3,
    }
    for ch, want in pairs(expect) do
      H.eq(draw.width(ch), want,
        ("advance of '%s'"):format(ch == ' ' and 'space' or ch))
    end
    -- and a whole command, where the 2px dot is what a flat grid gets wrong
    H.eq(draw.width('TR.P A'), 22, 'TR.P A is 22px, not the 24 a 4px cell says')
    H.eq(draw.width('CV 1 V 5'), 32, 'CV 1 V 5 happens to land on 32')
  end)

  H.test('a glyph draws the bits font.c holds', function()
    local _, draw = fresh()
    draw.begin()
    draw.text_at(0, 0, 'A', 15)
    -- font.c 0x41: first 2, last 1, data { .., .., 0x7c, 0x12, 0x7c, .. }
    -- so three columns of 0x7c, 0x12, 0x7c -- bits counting down from the top
    H.eq(art(draw, 0, 0, 3, 8), table.concat({
      '...',
      '.#.',
      '#.#',
      '#.#',
      '###',
      '#.#',
      '#.#',
      '...',
    }, '\n'), 'an A')
  end)

  H.test('text is upper-cased when asked', function()
    local _, draw = fresh()
    draw.configure(true)
    draw.begin()
    draw.text_at(0, 0, 'a', 15)
    local upper = art(draw, 0, 0, 3, 8)
    draw.configure(false)
    draw.begin()
    draw.text_at(0, 0, 'a', 15)
    H.ok(art(draw, 0, 0, 3, 8) ~= upper, 'lower case draws a different glyph')
    draw.configure(true)
  end)

  H.test('the cursor lands on the character it marks', function()
    local _, draw = fresh()
    -- 'TR.P A' with the cursor on the P: prefix 'TR.' is 4 + 4 + 2 = 10px, so
    -- a flat 4px cell would put the block at 12 and cover the wrong character.
    draw.begin()
    draw.line_with_cursor(0, 7, 'TR.P A', 3, draw.NORMAL)
    -- the block is bright except where the glyph punches through at level 0,
    -- so check the top row, which P leaves clear across all three columns
    for x = 10, 13 do
      H.eq(px(draw, x, 56), 15, ('the cursor block is lit at x=%d'):format(x))
    end
    H.eq(px(draw, 9, 56), 0, 'and starts no earlier than x=10')
    H.eq(px(draw, 14, 56), 0, 'four wide, the advance of P')
    -- the character itself is knocked out of the block
    H.eq(px(draw, 10, 57), 0, 'P draws through the cursor at level 0')
  end)

  H.test('a narrow character gets a narrow cursor', function()
    local _, draw = fresh()
    draw.begin()
    draw.line_with_cursor(0, 0, 'TR.P', 2, draw.NORMAL)   -- cursor on the '.'
    H.eq(px(draw, 8, 0) ~= 0, true, 'block starts after T and R, at x=8')
    H.eq(px(draw, 10, 0), 0, 'and is 2 wide, the advance of a dot')
  end)

  H.test('the frame handed over is one byte per pixel', function()
    local rec, draw = fresh()
    draw.begin()
    draw.finish()
    H.eq(#rec.poked, 128 * 64, 'a full screen of bytes')
  end)
end)

H.suite('draw: every mode fits the screen', function()
  H.test('no mode draws below the last row', function()
    local _, draw, ui, st = fresh()

    local ss = st.SceneState.new(0)
    ui.set_scene(ss, require('scene').new_text())
    local tok = require 'tokenizer'
    for l = 0, 5 do
      ss:overwrite_script_command(0, l, tok.parse('CV 1 V ' .. l))
    end
    ss.patterns[0].len = 20
    ui.preset.set_index({ [0] = 'A SCENE', [1] = 'ANOTHER' })

    for _, mode in ipairs({ ui.modes.LIVE, ui.modes.EDIT, ui.modes.PATTERN,
                            ui.modes.PRESET_R, ui.modes.PRESET_W,
                            ui.modes.HELP }) do
      ui.modes.set(mode)
      ui.redraw('')
      H.eq(draw.overflow, 0,
        ('%s drew %d pixels past the bottom of the screen')
          :format(mode, draw.overflow))
      -- and it drew something at all
      local buf = draw.buffer()
      local lit = 0
      for i = 1, 128 * 64 do if buf[i] ~= 0 then lit = lit + 1 end end
      H.ok(lit > 0, ('%s drew nothing at all'):format(mode))
    end
  end)
end)

H.suite('draw: the live mode activity strip', function()
  -- Every pixel here is teletype/module/live_mode.c:658-728. Expectations are
  -- rebuilt from ui/activity's own tables rather than written out a second
  -- time, so a typo in either the glyphs or the coordinates fails.

  --- the strip's pixels as a level -> { ['x,y'] = true } map
  local function strip(draw)
    local by_level = {}
    for y = 0, 7 do
      for x = 85, 127 do
        local v = px(draw, x, y)
        if v ~= 0 then
          by_level[v] = by_level[v] or {}
          by_level[v][('%d,%d'):format(x, y)] = true
        end
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
    local _, draw, ui, st = fresh()
    ui.set_scene(st.SceneState.new(0), require('scene').new_text())
    ui.modes.set(ui.modes.LIVE)
    ui.redraw('')

    local by_level = strip(draw)
    local expected = {}
    for _, icon in ipairs(ui.activity.ICONS) do
      expand(ui.activity.GLYPH[icon.name], icon.x, expected)
    end
    for i = 0, 7 do
      expected[('%d,%d'):format(87 + i, i % 2 == 0 and 1 or 3)] = true
    end

    H.eq(keys(by_level[15]), '', 'nothing is lit')
    H.eq(keys(by_level[1]), keys(expected), 'every glyph pixel is dim')
  end)

  H.test('each flag lights its own glyph and only that one', function()
    local _, draw, ui, st = fresh()
    local ss = st.SceneState.new(0)
    ui.set_scene(ss, require('scene').new_text())
    ss.delay.count = 1
    ss.stack_op.top = 1
    ss:overwrite_script_command(st.METRO_SCRIPT, 0,
      require('tokenizer').parse('TR.P A'))
    ss.variables.mutes[0] = true

    ui.modes.set(ui.modes.LIVE)
    ui.redraw('')

    local by_level = strip(draw)
    local lit = {}
    expand(ui.activity.GLYPH.delay, 106, lit)
    expand(ui.activity.GLYPH.stack, 114, lit)
    expand(ui.activity.GLYPH.metro, 122, lit)
    lit['87,1'] = true                 -- script 0, muted

    local dim = {}
    expand(ui.activity.GLYPH.slew, 98, dim)  -- nothing slews without hardware
    for i = 1, 7 do
      dim[('%d,%d'):format(87 + i, i % 2 == 0 and 1 or 3)] = true
    end

    H.eq(keys(by_level[15]), keys(lit), 'delay, stack, metro and one mute')
    H.eq(keys(by_level[1]), keys(dim), 'slew and the seven unmuted scripts')
  end)

  H.test('a metro timer with an empty script leaves the icon dim', function()
    local _, draw, ui, st = fresh()
    local ss = st.SceneState.new(0)
    ui.set_scene(ss, require('scene').new_text())
    ss.variables.m_act = 1
    ui.modes.set(ui.modes.LIVE)
    ui.redraw('')
    -- main.c:1028-1031 wants both the timer and a non-empty script
    H.eq(strip(draw)[15], nil, 'the metro icon needs something to run')
  end)

  H.test('falling polarity widens a mute mark to two pixels', function()
    local _, draw, ui, st = fresh()
    local ss = st.SceneState.new(0)
    ui.set_scene(ss, require('scene').new_text())
    ss.variables.script_pol[0] = 3      -- both edges
    ss.variables.script_pol[1] = 2      -- falling only
    ui.modes.set(ui.modes.LIVE)
    ui.redraw('')

    local dim = strip(draw)[1]
    H.ok(dim['87,1'] and dim['88,1'], 'script 0 takes two pixels on row 1')
    H.ok(dim['89,3'] and not dim['88,3'],
      'script 1 falling-only sits one pixel right, on row 3')
  end)

  H.test('the status text keeps out of the band', function()
    local _, draw, ui, st = fresh()
    ui.set_scene(st.SceneState.new(0), require('scene').new_text())
    ui.modes.set(ui.modes.LIVE)
    ui.redraw('')
    local without = keys(strip(draw)[1])

    ui.redraw('I2C?2')
    H.eq(keys(strip(draw)[1]), without,
      'a status string changes nothing inside x=85..127')
  end)

  H.test('no other mode draws the strip', function()
    local _, draw, ui, st = fresh()
    local ss = st.SceneState.new(0)
    ui.set_scene(ss, require('scene').new_text())
    for _, mode in ipairs({ ui.modes.PATTERN, ui.modes.HELP }) do
      ui.modes.set(mode)
      ui.redraw('')
      -- the icons are LIVE only; any level-1 pixels in the band would be them
      H.eq(strip(draw)[1], nil,
        ('%s drew indicator pixels; they are LIVE only'):format(mode))
    end
  end)
end)

_G.screen = nil
