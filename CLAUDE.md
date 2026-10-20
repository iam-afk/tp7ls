# tp7ls: language server for Turbo Pascal 7 — Free Pascal port

Goal: port the working Python prototype (`python/`, see `python/CLAUDE.md`) to Free Pascal 3.2.2 (`/usr/bin/fpc`,
x86_64-linux). The prototype stays as the **reference implementation**: when the port and the prototype disagree,
the prototype is right unless the owner says otherwise. Everything in `python/CLAUDE.md` under "Fixed decisions"
and "Rules of the work" applies to the port as well (TP7 only, cp866 + CRLF, hard-fixed formatting, no false positives,
no guessed TPU facts).

## Layout
- `src/` the port. `src/tp7ls.lpr` entry point; units are named after the Python modules
  (`tp7lex.py` -> `src/tp7lex.pas`, `tpu_dump.py` -> `src/tpudump.pas`, ...).
- `tests/` FPCUnit: `tests/tp7tests.lpr` runner, one unit per Python suite (`test_tp7lex.py` -> `tests/tlex.pas`).
  `tests/tsmoke.pas` only checks the harness; delete it when the first real suite lands.
- `tools/compare.py` differential check: runs the prototype and the port's CLI on the same files and diffs
  (`lex`: token dump, format in the script's docstring; `fmt`: formatter output, byte-exact).
  It expects `build/tp7lex` and `build/tp7fmt` CLI programs (sources `src/tp7lexcli.lpr`, ... to be added).
- `python/` the prototype, unchanged except for this move. Its tests run from any directory.
- `build/` output (ignored by git).

## Build and test
- `make` builds `build/tp7ls`; `make test` builds and runs the FPCUnit tests (exit status != 0 on failure).
- `make pytest DATA=dir` runs the prototype's suites; `dir` holds the owner's samples (TURBO.TPL, GRAPH.TPU,
  WINXP.TPU, polsk.pas, ... see `python/README.txt`). Without it most suites fail with errors (missing files).
  Known locations here: `../BP/BIN/TURBO.TPL`, `../BP/UNITS/GRAPH.TPU`, `../vdisk/WINXP.*`, `../robot/polsk.pas`,
  `../robot/option.pas`; `polsk_formatted.pas`, `option_formatted.pas`, `TEST.PAS` are not on this machine.
- `make compare FILES="python/samples ../robot"` runs `tools/compare.py` for lexer and formatter.
- Compiler flags are in the `Makefile` (`-Mobjfpc -Sh` plus range / overflow / I/O checks and assertions);
  every unit also starts with `{$mode objfpc}{$H+}` so it builds without the Makefile.

## Port order
1. Lexer (`tp7lex`) + CLI with `--dump`; port `test_tp7lex.py`; `compare.py lex` clean on all available sources.
2. Parser (`tp7parse`, including `prepare`: IFDEF, `{$I}`); port `test_tp7parse.py`, `test_tp7inc.py`.
3. Formatter (`tp7fmt`) + CLI; port `test_tp7fmt.py`; `compare.py fmt` byte-exact.
4. Then `tpu_dump`, `tp7sema`, `tp7types`, `tp7stub`, `tp7index`, and the server (`tp7lsp`; JSON via fcl-json).

## Open questions for the owner
- Internal string type. Proposal: `UnicodeString` (UTF-16) for source text. cp866 is entirely in the BMP, so one
  Python character = one UTF-16 unit: token offsets match the prototype, and LSP columns (UTF-16) need no conversion.
  Disk files are decoded cp866 -> UTF-16 on read; the editor's UTF-8 is decoded on receipt.

## Rules of the work
- Port behaviour, not just code: every ported module gets its Python suite ported and a clean `compare.py` run.
- Keep the Python idioms out where Pascal has a plain way (records / classes, `TFPGList` or arrays), but keep the
  algorithms and the names of the prototype so the two can be read side by side.
- Do not change the prototype to suit the port; if the prototype has a bug, tell the owner and fix it in both.
