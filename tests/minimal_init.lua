local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local plenary = vim.env.PLENARY_DIR or (root .. "/deps/plenary.nvim")

vim.opt.runtimepath = { root, plenary, vim.env.VIMRUNTIME }
vim.opt.packpath = {}
vim.cmd("runtime plugin/plenary.vim")
