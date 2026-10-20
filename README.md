# tp7ls

Language server для Turbo Pascal 7.

- `python/` — рабочий прототип на Python (описание: `python/README.txt`); эталон и спецификация для порта.
- `src/`, `tests/` — порт на Free Pascal 3.2.2 (в работе; порядок и правила — в `CLAUDE.md`).
- `tools/compare.py` — сверка порта с прототипом на одних и тех же файлах.

```
make                       # build/tp7ls
make test                  # тесты порта (FPCUnit), образцы из testdata/
make pytest                # тесты прототипа на тех же образцах
make compare FILES="testdata python/samples"
```
