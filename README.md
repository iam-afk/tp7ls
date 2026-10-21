# tp7ls

Language server для Turbo Pascal 7.

- `python/` — рабочий прототип на Python (описание: `python/README.txt`); эталон и спецификация для порта.
- `src/`, `tests/` — порт на Free Pascal 3.2.2 (порядок и правила — в `CLAUDE.md`). `build/tp7ls` — сервер (LSP
  через stdio), заменяет `python3 python/tp7lsp.py`.
- `nvim/` — плагин для Neovim (установка и настройки: `nvim/README.md`).
- `tools/compare.py` — сверка порта с прототипом на одних и тех же файлах; `tools/pyproto.py` — протокольные тесты
  прототипа против сервера порта.

```
make                       # build/tp7ls
make test                  # тесты порта (FPCUnit), образцы из testdata/
make pytest                # тесты прототипа на тех же образцах
make prototest             # протокольные тесты прототипа против build/tp7ls
make compare FILES="testdata python/samples"
```
