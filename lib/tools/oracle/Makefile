# Builds the golden-fixture oracle against the unmodified teletype C core.
#
# TT points at the reference checkout; nothing here writes into it except the
# ragel-generated scanner/match_token sources, which teletype's own Makefiles
# generate in exactly the same place.

TT := ../../../../teletype

# -ffp-contract=off: clang fuses float multiply-adds into FMA instructions on
# arm64, which evaluate at higher intermediate precision. The AVR32 target has
# no FMA, so contraction makes the oracle *less* like the real firmware -- and
# it makes the CHAOS maps, which amplify tiny differences, drift from the port.
CFLAGS = -std=c99 -g -Wall -fno-common -ffp-contract=off -DSIM \
	-I$(TT)/src -I$(TT)/libavr32/src

CORE = \
	$(TT)/src/teletype.o $(TT)/src/command.o $(TT)/src/helpers.o \
	$(TT)/src/drum_helpers.o $(TT)/src/every.o $(TT)/src/match_token.o \
	$(TT)/src/scanner.o $(TT)/src/state.o $(TT)/src/table.o \
	$(TT)/src/turtle.o $(TT)/src/chaos.o $(TT)/src/scale.o \
	$(TT)/src/scene_serialization.o \
	$(TT)/src/ops/op.o $(TT)/src/ops/ansible.o $(TT)/src/ops/controlflow.o \
	$(TT)/src/ops/delay.o $(TT)/src/ops/earthsea.o $(TT)/src/ops/er301.o \
	$(TT)/src/ops/fader.o $(TT)/src/ops/hardware.o $(TT)/src/ops/i2c.o \
	$(TT)/src/ops/midi.o $(TT)/src/ops/justfriends.o \
	$(TT)/src/ops/meadowphysics.o $(TT)/src/ops/metronome.o \
	$(TT)/src/ops/maths.o $(TT)/src/ops/orca.o $(TT)/src/ops/patterns.o \
	$(TT)/src/ops/queue.o $(TT)/src/ops/stack.o $(TT)/src/ops/telex.o \
	$(TT)/src/ops/variables.o $(TT)/src/ops/whitewhale.o \
	$(TT)/src/ops/turtle.o $(TT)/src/ops/init.o $(TT)/src/ops/grid_ops.o \
	$(TT)/src/ops/matrixarchate.o $(TT)/src/ops/wslash.o \
	$(TT)/src/ops/seed.o $(TT)/src/ops/disting.o $(TT)/src/ops/wslashtape.o \
	$(TT)/src/ops/wslashsynth.o $(TT)/src/ops/wslashdelay.o \
	$(TT)/src/ops/wslash_shared.o $(TT)/src/ops/crow.o \
	$(TT)/src/ops/i2c2midi.o \
	$(TT)/libavr32/src/euclidean/data.o \
	$(TT)/libavr32/src/euclidean/euclidean.o \
	$(TT)/libavr32/src/music.o $(TT)/libavr32/src/util.o \
	$(TT)/libavr32/src/random.o

.PHONY: all clean

all: oracle

oracle: oracle.o $(CORE)
	$(CC) -o $@ $^ $(CFLAGS)

$(TT)/src/match_token.c: $(TT)/src/match_token.rl
	ragel -C -G2 $< -o $@

$(TT)/src/scanner.c: $(TT)/src/scanner.rl
	ragel -C -G2 $< -o $@

clean:
	rm -f oracle oracle.o
	rm -rf oracle.dSYM
