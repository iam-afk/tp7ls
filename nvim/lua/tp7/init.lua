local M = {}

local function plugin_root()
  local source = debug.getinfo(1, 'S').source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source))))
end

function M.default_server()
  local built = vim.fs.joinpath(vim.fs.dirname(plugin_root()), 'build', 'tp7ls')
  if vim.fn.executable(built) == 1 then
    return { built }
  end
  return { 'tp7ls' }
end

function M.setup(opts)
  opts = opts or {}
  local server = opts.server or M.default_server()
  local group = vim.api.nvim_create_augroup('tp7', { clear = true })
  local pas = { '*.pas', '*.PAS' }
  local hints = opts.inlay_hints == false and { parameters = false, constants = false, end_labels = 0 }
    or opts.inlay_hints or {}

  vim.filetype.add({ extension = { PAS = 'pascal' } })

  -- 'fileencodings' / 'fileformats' are global: changed only while a source is read
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
        return
      end
      local root = vim.fs.root(args.buf, { 'TURBO.TPL', '.git' }) or vim.fs.dirname(name)
      vim.lsp.start({
        name = 'tp7ls',
        cmd = server,
        root_dir = root,
        init_options = {
          tp7Dir = opts.tp7_dir,
          stubDir = opts.stub_dir,
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

  vim.api.nvim_set_hl(0, '@lsp.type.label', { link = 'Label', default = true })
  vim.api.nvim_set_hl(0, '@lsp.type.macro', { link = 'PreProc', default = true })
  vim.api.nvim_set_hl(0, '@lsp.typemod.function.defaultLibrary', { link = 'Special', default = true })
  vim.api.nvim_set_hl(0, '@lsp.typemod.type.defaultLibrary', { link = 'Type', default = true })
  vim.api.nvim_set_hl(0, 'LspInlayHint', { link = 'Comment', default = true })

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

  if opts.format_on_save ~= false then
    vim.api.nvim_create_autocmd('BufWritePre', {
      group = group,
      pattern = pas,
      callback = function(args)
        -- a file with syntax errors is refused by the server; saving must still work
        pcall(vim.lsp.buf.format, { bufnr = args.buf, name = 'tp7ls', timeout_ms = 3000 })
      end,
    })
  end
end

return M
