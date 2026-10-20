# tp7ls: language server for Turbo Pascal 7

Goal: a working language server for **Turbo Pascal 7 only** (not Delphi / Object Pascal / Free Pascal dialects).
The prototype is Python (this folder); it is to be ported to Free Pascal later. Editors: Neovim (`tp7.lua`) and Zed
(`zed-tp7/`, never built: crates.io was unreachable where it was written; needs `rustup target add wasm32-wasip1`).

## Fixed decisions (the owner's, do not reopen)
- Sources are **cp866 with CRLF**. Files on disk are read as cp866; the editor sends UTF-8.
- Formatting is **hard-fixed, no options**. Reference style: `polsk_formatted.pas`, `option_formatted.pas`.
  Blank line between declarations is mandatory; `else if` on one line; one field per line; lines over 120 chars wrap.
- Identifier case is normalized to the **declaration spelling** (also for System / other units).
- Conditional compilation (`{$IFDEF}`) and `{$I file}` are supported in the parser.
- Messages are in English; the owner talks Russian.

## Layout
- `tp7lex.py` lossless lexer; `tp7parse.py` tolerant CST parser (`prepare` handles IFDEF and `{$I}`);
  `tp7fmt.py` formatter (re-emits from the CST); `tp7sema.py` Binder (refs/decls/scopes) + Provider (units from .pas,
  .tpu, TURBO.TPL; overlay of open buffers); `tpu_dump.py` TPU/TPL reader; `tp7stub.py` generates read-only unit stubs;
  `tp7index.py` index of the project tree (units / includes in any subfolder); `tp7types.py` type model, type
  diagnostics, inlay hints; `tp7lsp.py` the server (LSP 3.17, stdio; reader thread, debounced diagnostics);
  `tp7.lua` Neovim setup; `tp7ls.py` entry point.
- Tests: `for t in test_tp7*.py test_tpu_dump.py; do python3 $t; done` (all must pass; ~16 suites).
  Some tests need `TURBO.TPL`, `GRAPH.TPU`, `WINXP.PAS`, ... from the owner's uploads: see `T.D` in `test_tp7lsp.py`.
  `samples/` holds SAMPLES.PAS/.TPU, OBJECTS.TPU, TYPES_*.PAS (valid and invalid code for the type rules).

## Rules of the work
- **No false positives.** A new diagnostic must be silent on anything not understood (UNKNOWN type is compatible
  with everything). Check against real programs (`WINXP.PAS`, `POLSK.PAS`, `TEST.PAS`, `option.pas`) before shipping.
- TPU format facts were verified on real samples (see comments marked `[verified: ...]` in `tpu_dump.py`). Do not
  guess new ones: ask the owner for a compiled sample (`SAMPLES.PAS` is the template for that).
- Server options (`initializationOptions`): `tp7Dir`, `stubDir`, `typeDiagnostics` (default true),
  `inlayHints {parameters, constants, endLabels}`.

## Done
Formatting, name normalization, diagnostics (unknown names / units, duplicates, unused, missing implementations,
type errors), hover (also the type of an expression on an operator / bracket / `^`), definition / declaration / typeDefinition / implementation, references, rename, document and
workspace symbols, completion, signature help, semantic tokens, selection / range formatting, code actions,
inlay hints, `{$I}`, object types and parameter names from TPU, unit stubs, project index.

## Known limitations
`packed` and `far` are not stored in TPU; variant records are shown flat; inline bytes are not decoded;
rename across `{$I}` files is refused; hex literals are not range-checked; `{$V-}` is ignored;
typed-constant initializers and declaration-part expressions are not type-checked.
Expression hover: a byte-sized or subrange integer operation is an anonymous `integer` (the guide widens bytes to
words); computed reals are `Real`, noted as Extended in {$N+} code ({$N} is not tracked).

## Next
1. Port to Free Pascal (lexer, parser, formatter first; keep the tests as the specification).
2. Build and try the Zed extension on a machine with network access.
