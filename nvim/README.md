# tp7 для Neovim

Плагин для Neovim >= 0.10: подключает language server `tp7ls` к исходникам Turbo Pascal 7 (`*.pas`, `*.PAS`).

Что делает:
- читает и пишет `*.pas` в cp866 с CRLF;
- запускает сервер один раз на проект (корень — папка с `TURBO.TPL` или `.git`, иначе папка файла);
- форматирует при сохранении (файл с синтаксическими ошибками сохраняется как есть);
- включает inlay hints и цвета для семантических токенов.

## Установка

Сервер: `make` в корне репозитория собирает `build/tp7ls`. Плагин сам находит его рядом с собой (`../build/tp7ls`);
иначе запускает `tp7ls` из `PATH`, или путь можно задать в `server`.

lazy.nvim:

```lua
{
  dir = '~/developer/minor/dos/tp7ls/nvim',
  config = function()
    require('tp7').setup({ tp7_dir = 'C:/TP' })
  end,
}
```

Без менеджера плагинов — в `init.lua`:

```lua
vim.opt.rtp:prepend('~/developer/minor/dos/tp7ls/nvim')
require('tp7').setup({ tp7_dir = 'C:/TP' })
```

## Настройки

```lua
require('tp7').setup({
  server = { '/путь/к/tp7ls' },   -- по умолчанию ../build/tp7ls рядом с плагином или tp7ls из PATH
  tp7_dir = 'C:/TP',              -- папка Turbo Pascal (BIN/TURBO.TPL, UNITS); или переменная TP7_DIR
  stub_dir = nil,                 -- куда писать заглушки модулей из TPU; по умолчанию ~/.cache/tp7ls/stubs
  type_diagnostics = true,        -- ошибки типов; false — только имена
  inlay_hints = { parameters = true, constants = true, end_labels = 25 },   -- false — выключить все
  format_on_save = true,
})
```

`end_labels` — имя подпрограммы после её `end`, если она не короче стольких строк (0 — не показывать).
Форматирование без опций; `:lua vim.lsp.buf.format()` — по запросу.
