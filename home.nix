{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  omz = "${pkgs.oh-my-zsh}/share/oh-my-zsh";
  dotfiles = "${config.home.homeDirectory}/dotfiles";

  alacritty-x11 = pkgs.writeShellScriptBin "alacritty" ''
    unset WAYLAND_DISPLAY
    exec /usr/bin/alacritty "$@"
  '';
in
{
  home.username = "kuangtatang";
  home.homeDirectory = "/home/kuangtatang";
  home.stateVersion = "26.05";

  targets.genericLinux.enable = true;

  home.sessionVariables = {
    EDITOR = "nvim";
  };

  home.sessionPath = [
    "$HOME/.local/bin"
  ];

  fonts.fontconfig.enable = true;

  home.packages = with pkgs; [
    alacritty-x11
    nerd-fonts.jetbrains-mono
    noto-fonts-cjk-sans

    ripgrep
    fd
    jq
    lsd
    delta
    zellij
    unzip
    p7zip
    wget
    tldr

    nodejs_22
    pnpm

    inputs.tuios.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];

  xdg.dataFile."applications/Alacritty.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Alacritty
    GenericName=Terminal
    Comment=A fast, cross-platform, OpenGL terminal emulator
    Exec=env -u WAYLAND_DISPLAY /usr/bin/alacritty
    Icon=Alacritty
    Terminal=false
    Categories=System;TerminalEmulator;
    StartupWMClass=Alacritty
  '';

  programs.alacritty = {
    enable = true;
    package = null;

    settings = {
      general.working_directory = "/home/kuangtatang";

      window = {
        padding = {
          x = 6;
          y = 6;
        };
        dynamic_padding = true;
      };

      font = {
        size = 14;
        normal.family = "JetBrainsMono Nerd Font";
      };

      terminal.shell = {
        program = "${pkgs.zsh}/bin/zsh";
        args = [ "-l" ];
      };
    };
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = false;
  };
  programs.zoxide.enable = true;
  programs.bat.enable = true;
  programs.lazygit.enable = true;
  programs.btop.enable = true;
  programs.starship = {
    enable = true;
    enableZshIntegration = false;
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.nh = {
    enable = true;
    flake = "${config.home.homeDirectory}/dotfiles";
  };

  programs.neovim = {
    enable = true;
    viAlias = true;
    vimAlias = true;
    sideloadInitLua = true;
    extraPackages = with pkgs; [
      # LSP
      bash-language-server
      clang-tools
      lua-language-server
      gopls
      nixd
      typescript-language-server
      typescript
      vscode-langservers-extracted
      yaml-language-server

      # conform.nvim
      stylua
      shfmt
      nixfmt

      # treesitter
      gcc
      tree-sitter

    ];
  };

  xdg.configFile."nvim".source = config.lib.file.mkOutOfStoreSymlink "${dotfiles}/nvim";

  programs.zsh = {
    enable = true;
    enableCompletion = true;

    history = {
      size = 50000;
      save = 50000;
      share = true;
      ignoreDups = true;
    };

    shellAliases = {
      ls = "lsd";
    };

    initContent = lib.mkMerge [
      ''
          setopt interactive_comments

          [[ -f ~/.zsh/secrets.zsh ]] && source ~/.zsh/secrets.zsh

          ZVM_VI_SURROUND_BINDKEY=s-prefix

          function zvm_vi_yank_to_clipboard(){
            zle vi-yank
            local data
            data=$(printf '%s' "$CUTBUFFER")
            case "$(uname -s)" in
              Darwin)
          command -v pbcopy >/dev/null 2>&1 && printf '%s' "$data" | pbcopy
          ;;
        Linux)
          if command -v wl-copy >/dev/null 2>&1; then
             printf '%s' "$data" | wl-copy
          elif command -v xclip >/dev/null 2>&1; then
             printf '%s' "$data" | xclip -selection clipboard
          elif command -v clip.exe >/dev/null 2>&1; then
             printf '%s' "$data" | clip.exe
          fi
          ;;
            esac
          }
          zle -N zvm_vi_yank_to_clipboard

          function zvm_after_init() {
            zmodload zsh/terminfo
            [[ -n "$terminfo[kcuu1]" ]] && bindkey -M viins "$terminfo[kcuu1]" history-substring-search-up
            [[ -n "$terminfo[kcud1]" ]] && bindkey -M viins "$terminfo[kcud1]" history-substring-search-down
            bindkey -M viins '^[[A' history-substring-search-up
            bindkey -M viins '^[[B' history-substring-search-down
            bindkey -M viins '^R' history-incremental-search-backward
            bindkey -M viins '^F' history-incremental-search-forward
          }

          function zvm_after_lazy_keybindings(){
           bindkey -M vicmd 'k' history-substring-search-up
           bindkey -M vicmd 'j' history-substring-search-down
           bindkey -M vicmd '/' history-incremental-search-forward
           bindkey -M vicmd '?' history-incremental-search-backward
           bindkey -M vicmd 'y' zvm_vi_yank_to_clipboard
           bindkey -M visual 'y' zvm_vi_yank_to_clipboard
          }

          source ${pkgs.zsh-vi-mode}/share/zsh-vi-mode/zsh-vi-mode.plugin.zsh

          source ${omz}/lib/git.zsh
          source ${omz}/lib/clipboard.zsh
          source ${omz}/plugins/git/git.plugin.zsh
          source ${omz}/plugins/extract/extract.plugin.zsh
          source ${omz}/plugins/colored-man-pages/colored-man-pages.plugin.zsh
          source ${omz}/plugins/copypath/copypath.plugin.zsh
          source ${omz}/plugins/copyfile/copyfile.plugin.zsh
          source ${omz}/plugins/command-not-found/command-not-found.plugin.zsh

          source ${pkgs.zsh-fzf-tab}/share/fzf-tab/fzf-tab.plugin.zsh
          source ${pkgs.zsh-autosuggestions}/share/zsh-autosuggestions/zsh-autosuggestions.plugin.zsh

          source ${pkgs.zsh-syntax-highlighting}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
          source ${pkgs.zsh-history-substring-search}/share/zsh-history-substring-search/zsh-history-substring-search.plugin.zsh
      ''

      (lib.mkAfter ''
        eval "$(starship init zsh)"

        autoload -Uz add-zsh-hook
        _osc133_precmd() { local s=$?; print -n "\e]133;D;$s\a\e]133;A\a"; }
        _osc133_preexec() { print -n "\e]133;C\a"; }
        add-zsh-hook precmd _osc133_precmd
        add-zsh-hook preexec _osc133_preexec
        PS1+=$'%{\e]133;B\a%}'
      '')
    ];
  };

  programs.home-manager.enable = true;
}
