# tp7ls

Language server для Turbo Pascal 7.

- `python/` — рабочий прототип на Python (описание: `python/README.txt`); эталон и спецификация для порта.
- `src/`, `tests/` — порт на Free Pascal 3.2.2 (в работе; порядок и правила — в `CLAUDE.md`).
- `tools/compare.py` — сверка порта с прототипом на одних и тех же файлах.

```
make                       # build/tp7ls
make test                  # тесты порта (FPCUnit)
make pytest DATA=папка     # тесты прототипа; в папке образцы: TURBO.TPL, GRAPH.TPU, WINXP.TPU, polsk.pas, ...
make compare FILES="python/samples ../robot"
```
