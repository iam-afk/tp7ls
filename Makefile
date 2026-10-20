# tp7ls, Free Pascal port.  `make` builds build/tp7ls, `make test` runs the FPCUnit tests,
# `make pytest DATA=dir` runs the Python prototype's suites (DATA: the owner's samples, TURBO.TPL etc.),
# `make compare FILES=...` checks the port against the prototype (see tools/compare.py).

FPC      ?= fpc
BUILD    := build
UNITS    := $(BUILD)/units
FPCFLAGS ?= -O2 -gl
FPCFLAGS += -B -Mobjfpc -Sh -Sa -Ci -Cr -Co -vewn -Fusrc -FU$(UNITS) -FE$(BUILD)

SRC      := $(wildcard src/*.pas src/*.lpr src/*.inc)
TESTSRC  := $(wildcard tests/*.pas tests/*.lpr)
PYTESTS  := $(wildcard python/test_tp7*.py) python/test_tpu_dump.py

.PHONY: all test pytest compare clean

all: $(BUILD)/tp7ls

$(UNITS):
	mkdir -p $@

$(BUILD)/tp7ls: $(SRC) | $(UNITS)
	$(FPC) $(FPCFLAGS) src/tp7ls.lpr

$(BUILD)/tp7tests: $(SRC) $(TESTSRC) | $(UNITS)
	$(FPC) $(FPCFLAGS) -Futests tests/tp7tests.lpr

test: $(BUILD)/tp7tests
	$(BUILD)/tp7tests

pytest:
	@rc=0; for t in $(PYTESTS); do echo "== $$t"; python3 $$t $(DATA) || rc=1; done; exit $$rc

compare: all
	python3 tools/compare.py lex $(FILES)
	python3 tools/compare.py fmt $(FILES)

clean:
	rm -rf $(BUILD)
