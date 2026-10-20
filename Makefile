FPC      ?= fpc
BUILD    := build
UNITS    := $(BUILD)/units
FPCFLAGS ?= -O2 -gl
FPCFLAGS += -B -Mobjfpc -Sh -Sa -Ci -Cr -Co -vewn -Fusrc -FU$(UNITS) -FE$(BUILD)

SRC      := $(wildcard src/*.pas src/*.lpr src/*.inc)
TESTSRC  := $(wildcard tests/*.pas tests/*.lpr)
PYTESTS  := $(wildcard python/test_tp7*.py) python/test_tpu_dump.py
CLIS     := $(BUILD)/tp7lex $(BUILD)/tp7parse $(BUILD)/tp7fmt

.PHONY: all test pytest compare clean

all: $(BUILD)/tp7ls $(CLIS)

$(UNITS):
	mkdir -p $@

$(BUILD)/tp7ls: $(SRC) | $(UNITS)
	$(FPC) $(FPCFLAGS) src/tp7ls.lpr

$(CLIS): $(BUILD)/%: src/%cli.lpr $(SRC) | $(UNITS)
	$(FPC) $(FPCFLAGS) -o$@ $<

$(BUILD)/tp7tests: $(SRC) $(TESTSRC) | $(UNITS)
	$(FPC) $(FPCFLAGS) -Futests tests/tp7tests.lpr

test: $(BUILD)/tp7tests
	TP7LS_DATA=$(DATA) $(BUILD)/tp7tests

pytest:
	@rc=0; for t in $(PYTESTS); do echo "== $$t"; python3 $$t $(DATA) || rc=1; done; exit $$rc

compare: all
	python3 tools/compare.py lex $(FILES)
	python3 tools/compare.py parse $(FILES)
	python3 tools/compare.py fmt $(FILES)

clean:
	rm -rf $(BUILD)
