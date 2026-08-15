-- unit_test.lua
--
-- The pieces the parse corpus doesn't reach: int16 arithmetic edges, the
-- helpers, and exact RNG sequence equivalence with libavr32.

local H = require 'harness'
local int16 = require 'int16'
local helpers = require 'helpers'
local Random = require 'random'

H.suite('int16', function()
  H.test('wrap is two\'s complement', function()
    H.eq(int16.wrap(0), 0, 'zero')
    H.eq(int16.wrap(32767), 32767, 'max')
    H.eq(int16.wrap(32768), -32768, 'max + 1 wraps')
    H.eq(int16.wrap(65535), -1, 'all ones')
    H.eq(int16.wrap(65536), 0, 'full turn')
    H.eq(int16.wrap(-32769), 32767, 'min - 1 wraps')
  end)

  H.test('clamp saturates instead of wrapping', function()
    H.eq(int16.clamp(32768), 32767, 'above max')
    H.eq(int16.clamp(-32769), -32768, 'below min')
    H.eq(int16.clamp(100), 100, 'in range')
  end)

  H.test('idiv truncates toward zero like C', function()
    -- lua's // floors, which differs from C for negative operands
    H.eq(int16.idiv(7, 2), 3, '7/2')
    H.eq(int16.idiv(-7, 2), -3, '-7/2 truncates, not floors')
    H.eq(int16.idiv(7, -2), -3, '7/-2')
    H.eq(int16.idiv(-7, -2), 3, '-7/-2')
    H.eq(int16.idiv(-6, 2), -3, 'exact negative division')
  end)

  H.test('imod sign follows the dividend', function()
    H.eq(int16.imod(7, 3), 1, '7%3')
    H.eq(int16.imod(-7, 3), -1, '-7%3 is negative in C')
    H.eq(int16.imod(7, -3), 1, '7%-3')
  end)
end)

H.suite('helpers', function()
  H.test('normalise_value clamps when not wrapping', function()
    H.eq(helpers.normalise_value(0, 10, 0, 5), 5, 'in range')
    H.eq(helpers.normalise_value(0, 10, 0, -1), 0, 'below clamps to min')
    H.eq(helpers.normalise_value(0, 10, 0, 11), 10, 'above clamps to max')
  end)

  H.test('normalise_value wraps to the far edge', function()
    -- note this is a jump to the opposite bound, not a modulo
    H.eq(helpers.normalise_value(0, 10, 1, -1), 10, 'below wraps to max')
    H.eq(helpers.normalise_value(0, 10, 1, 11), 0, 'above wraps to min')
    H.eq(helpers.normalise_value(0, 10, 1, -100), 10, 'far below still max')
  end)

  H.test('bit_reverse', function()
    H.eq(helpers.bit_reverse(1, 8), 128, 'lsb to msb')
    H.eq(helpers.bit_reverse(128, 8), 1, 'msb to lsb')
    H.eq(helpers.bit_reverse(0, 8), 0, 'zero')
    H.eq(helpers.bit_reverse(255, 8), 255, 'all ones')
  end)

  H.test('rev_bitstring_to_int reads left to right as bit 0 up', function()
    H.eq(helpers.rev_bitstring_to_int('1'), 1, 'single')
    H.eq(helpers.rev_bitstring_to_int('1000'), 1, 'leftmost is bit 0')
    H.eq(helpers.rev_bitstring_to_int('0001'), 8, 'rightmost is bit 3')
    H.eq(helpers.rev_bitstring_to_int('1111111111111111'), -1,
      'sixteen ones truncate to int16 -1')
  end)

  H.test('number formatters round-trip', function()
    H.eq(helpers.itoa_hex(0), 'X0', 'hex zero')
    H.eq(helpers.itoa_hex(255), 'XFF', 'hex 255')
    H.eq(helpers.itoa_hex(-1), 'XFFFF', 'hex -1')
    H.eq(helpers.itoa_bin(0), 'B0', 'bin zero')
    H.eq(helpers.itoa_bin(5), 'B101', 'bin 5')
    H.eq(helpers.itoa_bin(-1), 'B1111111111111111', 'bin -1')
    H.eq(helpers.itoa_rbin(0), 'R0', 'rbin zero')
    H.eq(helpers.itoa_rbin(1), 'R1', 'rbin 1')
    H.eq(helpers.itoa_rbin(8), 'R0001', 'rbin 8 drops trailing zeros')
    H.eq(helpers.itoa_rbin(-1), 'R1111111111111111', 'rbin -1')
  end)
end)

H.suite('random: lua vs libavr32', function()
  H.test('sequences match exactly', function()
    -- fixture: rand <seed> <index> <value>
    local by_seed = {}
    for _, line in ipairs(H.fixture('test/fixtures/random.tsv')) do
      local f = H.split_tsv(line)
      if f[1] == 'rand' then
        local seed = tonumber(f[2])
        by_seed[seed] = by_seed[seed] or {}
        by_seed[seed][tonumber(f[3])] = tonumber(f[4])
      end
    end

    local seeds = {}
    for s in pairs(by_seed) do seeds[#seeds + 1] = s end
    table.sort(seeds)
    H.ok(#seeds > 0, 'fixture had no seeds')

    for _, seed in ipairs(seeds) do
      local r = Random.new(seed)
      for i = 0, 31 do
        H.eq(r:next(), by_seed[seed][i],
          ('seed %d, draw %d'):format(seed, i))
      end
    end
  end)
end)
