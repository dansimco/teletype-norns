# Differences from hardware Teletype

This port is checked line-by-line against the real Teletype C implementation
(see `lib/tools/oracle/`), so the list below is exhaustive as far as the test
corpora reach. Anything not listed here is intended to behave identically.

## Deliberate design differences

| Area | Hardware | Here |
|---|---|---|
| Script triggers | `F1`–`F8` run scripts 1–8, `F9` = M, `F10` = I | norns reserves `F1`–`F5` for its own menu (`norns/lua/core/keyboard.lua:143`), so scripts are on `Ctrl+1`–`Ctrl+8`, `Ctrl+9` = M, `Ctrl+0` = I. `F6`–`F10` also work. |
| CV / TR outputs | 4 CV + 4 TR jacks | crow's 4 outputs, assigned per-output in params. Unmapped CV/TR still exist in scene state and can route to ansible or MIDI. |
| `IN`, `PARAM`, `STATE` | front-panel jacks and knob | no norns equivalent; readable and settable as plain state. |
| Grid ops (`G.*`) | 65 ops driving a monome grid | not implemented. They parse, validate and round-trip through scene files, but do nothing. |
| Pattern editing | the tracker edits a value in place as you type | digits are typed then committed with `Enter`. At 4 pixels per character there is no room to show a half-typed value distinctly, and this way a mistyped digit never lands in the pattern. |
| Font | the 6x8 bitmap font in `libavr32/src/font.c` | the same font, generated into `lib/ui/font.lua` and rendered by `lib/ui/draw.lua` into a byte-per-pixel buffer handed to `screen.poke` — the same shape as the hardware's `region`. Text is pixel-identical, and there is consequently no font or size choice in params. |
| Live mode history | scrollback only | up and down also recall previous commands, which a hardware Teletype has no need of because its scrollback is always visible. |
| Live mode indicators | slew, delay, stack, metro and the eight mute marks, top right | the same glyphs at the same pixels (`lib/ui/activity.lua`). Slew is inferred rather than observed: crow resolves ramps on-board, so the io layer tracks when each is due to land. |
| Top-right status text | nothing there but the indicators | the indicators own x 85–127 as on hardware. Left of them, live mode shows the crow connection state or an unreachable-i2c count when there is something to report; the mode label the port used to draw there is gone. |
| Peripheral i2c families | telex, disting, JF, W/, ER-301, i2c2midi, … | not implemented. They parse and round-trip; `IIA`/`IIS*`/`IIQ*` remain available as a raw escape hatch. |
| Un-seeded randomness | seeded from `rand()` at scene init | seeded deterministically. Once a scene sets `SEED` (or any `*.SEED`), both produce identical sequences. |
| `Q.RND` | uses stdlib `rand()`, so it ignores `SEED` even on hardware and cannot be reproduced | uses the scene's pattern generator, so it is seedable and deterministic |

## Undefined behaviour we do not reproduce

Each of these is an out-of-bounds read in the C. The value it returns depends
on what the linker happened to place next to the table, so it is not
reproducible even between builds of the firmware. We clamp instead, which is
deterministic. All are unreachable from sensible scene code.

| Op | Trigger | C behaviour | Here |
|---|---|---|---|
| `HZ x` | `x < -17340` (below `-table_n[127]`) | reads `table_n[-1]` | skips interpolation |
| `EXP x` | `x < -16320` | reads `table_exp[256]`, one past the end | clamps to `table_exp[255]` |
| `VV x` | `x == -32768` | int16 negation overflow escapes the `>1000` clamp, then indexes `table_v[-327]` | negation wraps as int16, table access clamped |
| `N.B`, `N.BX` | root outside `0..127` | `get_degree_in_bitmask_scale` indexes `table_n` unclamped | clamps to the table range |
| `P.PREV`, `PN.PREV` | pattern length 0 | index becomes -1, and `val[-1]` aliases the pattern's adjacent `end` struct field, so it returns 63 | returns 0 |
| `ANS.G` (read form) | always | declares a 3-byte i2c buffer but transmits 4; the trailing byte is uninitialised stack, which on the reference build aliases the `y` argument | sends a deterministic `0`; the 4-byte length is preserved |

## Ansible over crow

Teletype talks to an Ansible over i2c. This port builds the same packets and
then translates them into crow `ii` calls. Two consequences:

| | Hardware | Here |
|---|---|---|
| Reads (`CV 5`, `KR.PRE` with no argument, …) | synchronous — the i2c read blocks and the value is pushed straight onto the stack | crow's `ii` reads are **asynchronous**, and a Teletype op cannot block. A read returns the last cached value and requests a refresh, so a polling scene sees values one cycle stale. Zero until the first reply arrives. |
| Reads crow has no getter for (`KR.PG`, `KR.CUE`, `KR.DIR`, `LV.RES`, `ME.RES`) | return the module's value | return 0 and are counted as unavailable, so the UI can say so rather than reporting a plausible-looking stale zero |

**Writes go out through `ii.raw`, byte for byte.** crow does expose named
modules for some of this (`ii.ansible`, `ii.kria`, `ii.meadowphysics`,
`ii.levels`), and those are implemented as a fallback, but raw is the default
because it is strictly more faithful: the bytes Teletype builds are already in
the Ansible's own format, so there is no command name to map and no unit to
convert. It also means the families crow has *no* module for — Cycles
(`CY.*`), Arp mode (`ARP.*`), MIDI mode (`MID.*`) and the grid/arc passthrough
(`ANS.G*`, `ANS.A*`, `ANS.APP`) — work with no extra machinery.

It also sidesteps an ambiguity in the reference. Teletype computes Ansible
expander addresses as `0x20 + 2n`, which puts the third and fourth Ansible at
`0x24` and `0x26` — exactly where MIDI mode and Arp mode live — and the command
bytes collide as well (`II_MID_SLEW` and `II_ANSIBLE_TR` are both `1`). Nothing
in the packet distinguishes them, so we take no position: the bytes go out
unaltered, which is correct under either reading.

Reads still use the named `get()` calls, since `ii.raw` has no
request/response form. That means reads work against the first Ansible;
reads aimed at a second, third or fourth expander return 0 and are counted as
unavailable.

## Floating point

`CHAOS` is the only part of the language that uses floating point, and the C
uses 32-bit `float`. Lua has only doubles, so `lib/chaos.lua` rounds through
float32 (via `string.pack`) after every arithmetic step. The maps amplify tiny
differences by design, so without this they diverge within a dozen iterations.

The oracle is built with `-ffp-contract=off` for the same reason: clang on
arm64 fuses float multiply-adds into FMA instructions that evaluate at higher
intermediate precision, which the AVR32 target has no way to do. Turning
contraction off makes the oracle *more* faithful to the real firmware, not
less, and the CHAOS sequences then match exactly.

## Quirks we *do* reproduce

These look like bugs but are observable behaviour that scenes could depend on,
so they are preserved and covered by tests.

- **Leading-zero literals are octal.** `MATCH_NUMBER` calls `strtol` with base
  0, so `010` is 8, `08` is 0 and `099` is 0.
- **`|101` lexes as a number.** The Ragel class `[B|R]` admits `|`, but the
  value extraction only tests for `X`/`B`/`R`, so it falls through to base-0
  `strtol` and yields `NUMBER:0`.
- **A command may hold only 15 words.** The length check increments before
  comparing against `COMMAND_MAX_LENGTH`, so a 16th word is `E_LENGTH`.
- **Shift counts are masked to 5 bits.** Operands promote to 32-bit int, so
  `RSH 1 -100` is `1 << 4` = 16.
- **`BSET`/`BGET`/`BCLR`/`BTOG` do not reverse direction on a negative index**,
  unlike `RSH`/`LSH`; `BSET 0 -1` is `1 << 31`, whose low 16 bits are 0.
- **`QT` overflows its candidate.** `c`, `d` and `e` are `int16_t`, so
  `QT 32767 2` computes the upper candidate as -32768 and picks the lower one.
- **`MUL` saturates** to the int16 range rather than wrapping, unlike `ADD` and
  `SUB` which wrap.
- **`validate()` double-counts a setter in first position.** Upstream notes
  this is "technically wrong" but harmless; reproduced so the set of accepted
  and rejected lines matches exactly.
