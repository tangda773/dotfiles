# home-manager 模組：把 deploy.sh 包成 `deploy` 指令
#
# 放在 dotfiles 裡，例如：
#   dotfiles/home/deploy/default.nix   ← 這個檔（改名成 default.nix）
#   dotfiles/home/deploy/deploy.sh
#
# 在 home.nix 裡匯入：
#   imports = [ ./deploy ];
#
# 更新腳本：改 dotfiles 裡的 deploy.sh → home-manager switch
#   （這樣裝的 deploy 在唯讀的 /nix/store，--self-update 會提示你走這個流程）

{ pkgs, ... }:

let
  deploy = pkgs.writeShellApplication {
    name = "deploy";

    # 腳本用到的指令，由 Nix 提供，不必依賴系統有沒有裝
    runtimeInputs = with pkgs; [
      rsync
      openssh # macOS 若 ~/.ssh/config 用了 UseKeychain，請拿掉這行改用系統 ssh
      git
      curl
      coreutils
      gawk
      gnugrep
      gnused
      diffutils
    ];

    # build 時會跑 shellcheck，有警告就 build 失敗
    text = builtins.readFile ./deploy.sh;
  };
in
{
  home.packages = [ deploy ];

  # 所有專案共用的預設值（可選）：~/.config/deploy/config
  xdg.configFile."deploy/config".text = ''
    # USER_NAME=space
    # PORT=22
    # USE_GITIGNORE=1
  '';
}
