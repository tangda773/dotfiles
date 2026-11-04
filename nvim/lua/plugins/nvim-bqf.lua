local nix_fzf = vim.fn.expand('~/.nix-profile/share/vim-plugins/fzf')

return {
  'kevinhwang91/nvim-bqf',
  ft='qf',
  dependencies={

    -- optional
    vim.fn.isdirectory(nix_fzf) == 1
      and {dir = nix_fzf, name = 'fzf'}
      or {'junegunn/fzf', build = './install --bin'},

    -- optional, highly recommended
    {'nvim-treesitter/nvim-treesitter'},

  }
}
