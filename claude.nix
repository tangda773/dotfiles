# Claude Code via home-manager's programs.claude-code module.
#
# Import from your home.nix:   imports = [ ./claude.nix ];
# Needs `inputs` passed in, e.g. in flake.nix:
#   homeConfigurations.<you> = home-manager.lib.homeManagerConfiguration {
#     extraSpecialArgs = { inherit inputs; };
#     ...
#   };
#
# Expected layout next to this file:
#   claude/skills/gen-git-commit-msg/SKILL.md
{
  config,
  pkgs,
  inputs,
  ...
}:

let
  system = pkgs.stdenv.hostPlatform.system;

  # Verify output names with:
  #   nix flake show github:Gaurav-Gosain/tuios
  #   nix flake show github:dmtrKovalenko/fff.nvim
  tuios = inputs.tuios.packages.${system}.default;
  fff-mcp = inputs.fff.packages.${system}.fff-mcp;
in
{
  home.packages = [ tuios ];

  programs.claude-code = {
    enable = true;
    package = pkgs.claude-code;

    # Keep ~/.claude/settings.json writable. On each switch the values below
    # are merged in; everything else in the file (including what Claude Code
    # writes itself) is preserved.
    #
    # Caveat: a declared array REPLACES the existing one. So `permissions.ask`
    # is declared here, but `permissions.allow` is deliberately NOT, because
    # Claude Code adds to it when you pick "don't ask again".
    mutableSettings = true;

    settings = {
      # No Co-Authored-By / "Generated with Claude Code" on commits and PRs.
      # Newer Claude Code versions may use `attribution` instead; check /config.
      includeCoAuthoredBy = false;

      permissions.ask = [ "Bash(git commit:*)" ];
    };

    # Attribute-set form: each skill gets its own entry, so ~/.claude/skills
    # itself stays a normal directory and `tuios integration install` can
    # still add its skill there. (A plain path here would make the whole
    # skills directory a read-only link.)
    skills = {
      gen-git-commit-msg = ./claude/skills/gen-git-commit-msg;
    };

    mcpServers = {
      fff = {
        type = "stdio";
        command = "${fff-mcp}/bin/fff-mcp";
      };
    };

    # Optional: global ~/.claude/CLAUDE.md, managed (read-only) by home-manager.
    # Only enable if you don't already keep a hand-edited ~/.claude/CLAUDE.md.
    # context = ''
    #   For any file search or grep in the current git-indexed directory, use fff tools.
    # '';
    rules = {
      fff = ''
        For any file search or grep in the current git-indexed directory, use fff tools.
      '';
    };
  };
}
