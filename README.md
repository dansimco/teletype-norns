# teletype

A [monome teletype](https://monome.org/docs/teletype/) for norns.

The same stack language, the same scene files, the same keyboard-driven modes —
with outputs routed to **crow**, to a **monome ansible** over crow's i2c, and to
**MIDI**, since norns has no CV jacks of its own.

Scenes are the real Teletype `.txt` format, so they move between the module and
norns in either direction.

## Requires

- norns (or shield), version 3.0 or later
- a **USB keyboard** — the interface is keyboard-driven, as on the module.
  norns' encoders and keys work as a fallback but reach far less.
- **crow**, for CV and gates. Optional: the script runs without one and MIDI
  routing still works.
- optionally a **monome ansible** on crow's i2c bus.

## Install

Copy the whole folder to `~/dust/code/teletype/` — `lib/` and `crow/` included,
not just `teletype.lua`.

```
teletype/
├── teletype.lua      the script
├── lib/              modules, and the build tools under lib/tools/
├── crow/             the companion script uploaded to crow
├── test/
└── docs/
```

Only `teletype.lua` appears in norns' script browser. It scans recursively but
skips `lib/`, `crow/`, `test/`, `data/` and `docs/`, which is why the build
tools live under `lib/tools/` rather than a top-level `tools/`.

On load you should see `teletype: ui-N loaded` and, once crow answers,
`teletype: crow timing = companion`.

## Outputs

Teletype has four CV and four TR jacks; crow has four outputs. So each crow
output is assigned a role in **params → crow outputs**:

| default | |
|---|---|
| out 1 | CV 1 |
| out 2 | CV 2 |
| out 3 | TR A |
| out 4 | TR B |

Any of the eight destinations can be assigned to any output, or left off. A
destination that is not on a crow output still exists — it holds its value, and
can drive MIDI or an ansible.

**MIDI out** is per destination, in **params → teletype: midi out**. A CV set to
`pitch` and a TR set to `gate` on the same device and channel make a playable
voice: the CV sets the note, the gate plays it. A CV can also send a CC.

**Ansible** works as it does on hardware: `CV 5`–`CV 20` and `TR 5`–`TR 20`
address expanders over i2c, and the `KR.*`, `ME.*`, `LV.*`, `CY.*`, `ARP.*` and
`MID.*` families drive its apps. Writes go out as raw i2c through crow, byte for
byte identical to what the module sends.

### Pulse timing

On load, the script uploads `crow/teletype.lua` to the crow so gate width, slew
and polarity are resolved there rather than over serial. It is *not* written to
flash — your own crow script returns when crow reboots.

If the upload fails the script falls back to driving crow directly and says so
on screen (`crow:stock`). Everything still works, with looser timing. You can
force that mode in **params → crow outputs → timing**.

## Keys

The interface is Teletype's. The one change: norns claims `F1`–`F5` for its own
menu, so scripts are on **ctrl-number**.

| | |
|---|---|
| `Tab` | live → edit → pattern → live |
| `Esc` | load a scene |
| `Alt+Esc` | save a scene |
| `Alt+H` or `Alt+?` | help |
| `Ctrl+1`…`Ctrl+8` | run script 1–8 |
| `Ctrl+9` / `Ctrl+0` | run the M and I scripts |
| `F6`…`F10` | also run scripts 6, 7, 8, M, I |
| `Win+Esc` | panic: clear delays, the stack and any slews |

**Live mode.** Type a command, `Enter` runs it. Up and down walk the history.
`~` shows the variables. `[` or `]` jumps to the editor.

**Edit mode.** `[` and `]` change script, up and down change line. `Enter`
commits the edited line — but only if it parses *and* validates, so a
half-finished line never reaches a script. `Shift+Enter` inserts instead of
overwriting, `Alt+/` comments a line out, `Ctrl+Z` undoes.

**Pattern mode.** Arrows move; type digits and press `Enter` to set a value.
`Alt+S`, `Alt+E`, `Alt+L` set the loop start, end and length; `Alt+I` moves the
playhead.

**Save mode.** Type the scene description; plain up/down moves between its
lines, **shift** up/down picks the slot. The header shows what you would
overwrite.

The line editor is the module's, emacs-flavoured: `ctrl-a`/`ctrl-e` for line
ends, `ctrl-b`/`ctrl-f` to move, `ctrl-w` and `alt-d` for words, `ctrl-u` and
`ctrl-k` to kill to either end, `ctrl-x`/`ctrl-c`/`ctrl-v` to cut, copy, paste.

### Without a keyboard

E1 cycles live → edit → pattern. In edit mode E2 picks the script, E3 the line,
K2 runs it. In pattern mode E2 moves and E3 changes the value. Enough to drive a
scene you already wrote; not enough to write one.

## Scenes

Thirty-two slots in `~/dust/data/teletype/scenes/`, as `tt00.txt` … `tt31.txt`
in the module's own format. Copy one off a Teletype's USB stick and it loads
here; save one here and it loads on the module.

The scene's description is what the load browser lists, so the first line is
worth filling in.

## From maiden

Useful while writing, or when something is not behaving:

```lua
tt_run("CV 1 V 5")        -- run one line, as live mode would
tt_script(9, 1, "TR.P A") -- put a line on a script (9 = M, 10 = I)
tt_go(9)                  -- run a script
tt_show(9)                -- print a script back
tt_status()               -- crow mode, output routing, delays, i2c problems
tt_slots()                -- what the scene browser can see, and what is on disk
tt_kbd()                  -- why keyboard input might not be arriving
tt_keys(true)             -- echo key presses with their modifiers
tt_version()              -- script and lib versions; catches a partial copy
```

## Differences from the module

See [docs/differences.md](docs/differences.md). Briefly: grid ops are not
implemented; `IN`, `PARAM` and `STATE` have no jacks to read; ansible reads are
one cycle stale because crow's i2c reads are asynchronous; and a handful of
out-of-bounds reads in the C are clamped rather than reproduced.

## Development

The language core has no norns dependencies and is tested against the **real
Teletype C implementation**. `lib/tools/oracle/` links the reference sources and
emits golden data; the Lua is diffed against it for parsing, execution,
accumulated scene state, and the exact i2c bytes each op puts on the wire.

```sh
make test        # ~97 tests, ~77k assertions
make fixtures    # regenerate the golden data from the C
make generated   # regenerate lib/tables.lua, ops/manifest.lua, ops/help.lua
```

Needs `lua5.4`, `ragel` and a C compiler, plus the teletype checkout beside this
one with its submodule:

```sh
git -C ../teletype submodule update --init libavr32
```

There is also a terminal Teletype, which needs none of the above:

```sh
lua5.4 lib/tools/repl.lua ../teletype/presets/tt00.txt
```

## Credits

The language, the scene format and the op semantics are
[monome's](https://github.com/monome/teletype), by Brian Crabtree, Kelli Cain,
Brendon Cassidy, Tom Armitage, Sam Doshi and many others. This is a port, not a
redesign; where the two disagree, the module is right.
