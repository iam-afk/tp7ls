-- tp7.lua: Turbo Pascal 7 language server for Neovim (needs Neovim >= 0.10).
--
-- Install:  put this file at ~/.config/nvim/lua/tp7.lua, keep tp7lsp.py and its sibling modules
--           (tp7lex.py tp7parse.py tp7fmt.py tp7sema.py tp7stub.py tp7index.py tp7types.py tpu_dump.py) together in ONE directory, then in init.lua:
--
--   require('tp7').setup({
--     server  = { 'python3', vim.fn.expand('~/tp7/tp7lsp.py') },
--     tp7_dir = 'C:/TP',          -- the Turbo Pascal directory (BIN/TURBO.TPL, UNITS); or export TP7_DIR instead
--     type_diagnostics = true,    -- type errors (assignments, conditions, calls); false = names only
--     inlay_hints = { parameters = true, constants = true, end_labels = 25 },   -- false / nil fields = off;
--                                   -- end_labels: the name after `end` of routines at least that many lines long
--   })
--
-- What it does: opens *.pas as DOS text (cp866, CRLF), starts the server once per project, formats on save.
-- Formatting has no options by design.  :lua vim.lsp.buf.format() formats on demand.

local M = {}

function M.setup(opts)
  opts = opts or {}
  local server = opts.server or { 'python3', vim.fn.expand('~/tp7/tp7lsp.py') }
  local group = vim.api.nvim_create_augroup('tp7', { clear = true })
  local pas = { '*.pas', '*.PAS' }
  local hints = opts.inlay_hints == false and { parameters = false, constants = false, end_labels = 0 } or opts.inlay_hints or {}

  vim.filetype.add({ extension = { PAS = 'pascal' } })

  -- DOS sources: cp866 + CRLF.  'fileencodings' / 'fileformats' are global options, so they are changed just
  -- for the duration of the read and restored afterwards.
  local saved
  vim.api.nvim_create_autocmd('BufReadPre', {
    group = group,
    pattern = pas,
    callback = function()
      saved = { vim.o.fileencodings, vim.o.fileformats }
      vim.o.fileencodings = 'cp866'
      vim.o.fileformats = 'dos,unix'
    end,
  })
  vim.api.nvim_create_autocmd('BufReadPost', {
    group = group,
    pattern = pas,
    callback = function()
      if saved then
        vim.o.fileencodings, vim.o.fileformats = saved[1], saved[2]
        saved = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufNewFile', {
    group = group,
    pattern = pas,
    callback = function()
      vim.bo.fileencoding = 'cp866'
      vim.bo.fileformat = 'dos'
    end,
  })

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'pascal',
    callback = function(args)
      local name = vim.api.nvim_buf_get_name(args.buf)
      if not name:lower():match('%.pas$') then
        return                                   -- .pp / .inc and friends are not TP7 sources
      end
      local root = vim.fs.root(args.buf, { 'TURBO.TPL', '.git' }) or vim.fs.dirname(name)
      vim.lsp.start({
        name = 'tp7ls',
        cmd = server,
        root_dir = root,
        init_options = {
          tp7Dir = opts.tp7_dir,
          typeDiagnostics = opts.type_diagnostics ~= false,
          inlayHints = {
            parameters = hints.parameters ~= false,
            constants = hints.constants ~= false,
            endLabels = hints.end_labels == nil and 25 or (hints.end_labels or 0),
          },
        },
      }, { bufnr = args.buf })
    end,
  })

  -- semantic tokens (Neovim colours them itself); the two custom/unusual types get sensible defaults, and
  -- inactive {$IFDEF} branches arrive as `comment`.  Override these links in your colourscheme if you like.
  vim.api.nvim_set_hl(0, '@lsp.type.label', { link = 'Label', default = true })
  vim.api.nvim_set_hl(0, '@lsp.type.macro', { link = 'PreProc', default = true })
  vim.api.nvim_set_hl(0, '@lsp.typemod.function.defaultLibrary', { link = 'Special', default = true })
  vim.api.nvim_set_hl(0, '@lsp.typemod.type.defaultLibrary', { link = 'Type', default = true })

  -- inlay hints (parameter names, constant types, `{ Name }` after a long routine): Neovim >= 0.10
  if opts.inlay_hints ~= false then
    vim.api.nvim_create_autocmd('LspAttach', {
      group = group,
      callback = function(args)
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if client and client.name == 'tp7ls' and vim.lsp.inlay_hint then
          vim.lsp.inlay_hint.enable(true, { bufnr = args.buf })
        end
      end,
    })
  end
  vim.api.nvim_set_hl(0, 'LspInlayHint', { link = 'Comment', default = true })

  if opts.format_on_save ~= false then
    vim.api.nvim_create_autocmd('BufWritePre', {
      group = group,
      pattern = pas,
      callback = function(args)
        -- a file with syntax errors is not formatted (the server says why); saving must still work
        pcall(vim.lsp.buf.format, { bufnr = args.buf, name = 'tp7ls', timeout_ms = 3000 })
      end,
    })
  end
end

return M
