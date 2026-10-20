tp7ls - Language Server для Turbo Pascal 7 (прототип на Python)

Файлы
  tp7lex.py      лексер без потерь
  tp7parse.py    толерантный парсер (CST), условная компиляция
  tp7fmt.py      форматтер, фиксированный стиль
  tp7sema.py     разрешение имён и нормализация регистра идентификаторов
  tpu_dump.py    чтение TPU/TPL (таблицы символов, написания имён)
  tp7stub.py     заглушки (stub) модулей без исходников: interface-текст из TPU/TPL, к нему ведёт go to definition
  tp7lsp.py      LSP-сервер по stdio: форматирование, диагностика, go to declaration / definition, диагностики (синтаксис, неизвестные модули и идентификаторы, неиспользуемые var/const/type и uses - серой подсказкой, повторные объявления, подпрограммы и методы без реализации), documentSymbol, hover (на операторе, скобке, ^ - тип выражения), typeDefinition, implementation, typeHierarchy, signatureHelp, completion, selectionRange, rangeFormatting, workspace/symbol, codeAction, documentHighlight, references, rename, semantic tokens
  tp7.lua        конфиг для neovim (0.10+): cp866, CRLF, запуск сервера, форматирование при сохранении
  test_*.py      тесты (test_tp7oop.py - object и методы, test_tp7stub.py - заглушки, test_tp7diag.py - диагностики, подсказки сигнатур, автодополнение, test_tp7perf.py - очередь, кэши, быстрый лексер, test_tp7inc.py - {$I файл}, test_tp7tpuobj.py - object из TPU (WINXP.TPU), test_tp7edit.py - selectionRange, rangeFormatting, workspace/symbol, codeAction)
  std_names.tsv  словарь написаний стандартных имён (из TURBO.TPL и GRAPH.TPU)

Запуск (Python 3, проверено на 3.13; все модули должны лежать в одной папке)
  python3 tp7fmt.py FILE.PAS --normalize --path DIR --tpl TURBO.TPL -o OUT.PAS
  python3 tp7lsp.py        # сервер; папку TP задайте через TP7_DIR или initializationOptions.tp7Dir
  python3 tp7stub.py UNIT.TPU   # напечатать заглушку модуля
  Заглушки пишутся в initializationOptions.stubDir / TP7LS_STUB_DIR / ~/.cache/tp7ls/stubs (только для чтения)

Тесты
  Нужны ваши образцы в одной папке: TURBO.TPL, GRAPH.TPU, POLSK.TPU, TEST.TPU, polsk.pas, option.pas, TEST.PAS,
  polsk_formatted.pas, option_formatted.pas, WINXP.TPU (+ WINXP.PAS для сверки).  Папку передайте аргументом:
  python3 test_tp7lex.py DIR   (и так же для остальных test_*.py)
