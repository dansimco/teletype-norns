# norns-teletype
#
# The language core is plain lua with no norns dependencies, so it is tested on
# the dev machine against the real teletype C implementation. `make fixtures`
# regenerates the golden data from that C core; `make test` diffs the lua port
# against it.
#
# Requires: lua 5.4 (norns itself runs 5.3; the port uses no 5.4-only feature),
# ragel and a C compiler for the oracle, and the teletype checkout beside this
# one with its libavr32 submodule initialised:
#
#   git -C ../teletype submodule update --init libavr32

LUA ?= $(shell command -v lua5.4 2>/dev/null || echo /opt/homebrew/opt/lua@5.4/bin/lua5.4)
ORACLE = lib/tools/oracle/oracle
FIXTURES = test/fixtures

.PHONY: all test fixtures oracle generated clean distclean

all: test

# ---------------------------------------------------------------------- tests

# TT_COVERAGE_STRICT makes an unimplemented in-scope op a failure rather than a
# note. Every in-scope op is implemented, so this stays on to keep it that way.
test: $(FIXTURES)/parse.tsv $(FIXTURES)/random.tsv $(FIXTURES)/process.tsv \
      $(FIXTURES)/scenes
	@TT_COVERAGE_STRICT=1 $(LUA) test/run.lua

# ------------------------------------------------------------------- fixtures

oracle:
	@$(MAKE) -s -C lib/tools/oracle

fixtures: oracle
	@$(ORACLE) ops    > $(FIXTURES)/ops.tsv
	@$(ORACLE) tables > $(FIXTURES)/tables.tsv
	@$(ORACLE) random > $(FIXTURES)/random.tsv
	@$(LUA) lib/tools/gen_corpus.lua
	@$(ORACLE) parse  < $(FIXTURES)/parse_corpus.txt > $(FIXTURES)/parse.tsv
	@$(LUA) lib/tools/gen_process_corpus.lua
	@$(ORACLE) process < $(FIXTURES)/process_corpus.txt > $(FIXTURES)/process.tsv
	@mkdir -p $(FIXTURES)/scenes
	@for f in ../teletype/presets/*.txt; do \
		$(ORACLE) scene "$$f" > "$(FIXTURES)/scenes/$$(basename $$f)"; done
	@echo "fixtures regenerated"

$(FIXTURES)/parse.tsv $(FIXTURES)/random.tsv $(FIXTURES)/ops.tsv \
$(FIXTURES)/tables.tsv $(FIXTURES)/process.tsv $(FIXTURES)/scenes:
	@$(MAKE) -s fixtures

# --------------------------------------------------------------- generated lua

# lib/tables.lua, lib/ops/manifest.lua and lib/ui/font.lua are checked in so the
# script runs on a norns without any of the above toolchain; regenerate them
# when the reference teletype checkout moves.
#
# gen_font needs only the vendored font.c, not the oracle, so it is listed last
# and costs nothing.
generated: $(FIXTURES)/tables.tsv $(FIXTURES)/ops.tsv
	@$(LUA) lib/ui/tools/gen_tables.lua
	@$(LUA) lib/ui/tools/gen_manifest.lua
	@$(LUA) lib/ui/tools/gen_help.lua
	@$(LUA) lib/ui/tools/gen_font.lua

# --------------------------------------------------------------------- cleanup

clean:
	@$(MAKE) -s -C lib/tools/oracle clean

# also drops the generated fixtures; `make fixtures` rebuilds them
distclean: clean
	@rm -f $(FIXTURES)/*.tsv $(FIXTURES)/parse_corpus.txt
	@rm -rf $(FIXTURES)/scenes
