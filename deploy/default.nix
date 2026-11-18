# home-manager module: package deploy.sh as the `deploy` command
#
# Files:
#   dotfiles/deploy/default.nix   ← this file
#   dotfiles/deploy/deploy.sh
#
# Import it in dotfiles/home.nix:
#   imports = [ ./deploy ];
#
# To update the script: edit deploy.sh in dotfiles → home-manager switch
#   (this install lives in the read-only /nix/store; --self-update points you to this workflow)

{ pkgs, ... }:

let
  deploy = pkgs.writeShellApplication {
    name = "deploy";

    # Commands the script uses, provided by Nix so the system needn't have them
    runtimeInputs = with pkgs; [
      rsync
      openssh # on macOS, if ~/.ssh/config uses UseKeychain, drop this line to use the system ssh
      git
      curl
      coreutils
      gawk
      gnugrep
      gnused
      diffutils
    ];

    # shellcheck runs at build time; any warning fails the build
    text = builtins.readFile ./deploy.sh;
  };
in
{
  home.packages = [ deploy ];

  # Defaults shared by all projects (optional): ~/.config/deploy/config
  xdg.configFile."deploy/config".text = ''
    # USER_NAME=space
    # PORT=22
    # USE_GITIGNORE=1
  '';
}
