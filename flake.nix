{
  description = "nix-gstack — Nix packaging for gstack, consumable by NUR";

  inputs = {
    # Track the rolling `nixos-unstable` channel so gstack picks up recent Bun
    # and Node releases. Switch to `nixos-XX.YY` if you'd rather have boring
    # upgrades.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    systems.url = "github:nix-systems/default";

    devshell = {
      url = "github:numtide/devshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # `agent-skill-flake` is the builder library, not a skill — it provides the
    # `devshellSkillsHook` that wires the dev-shell skill set in below. The skill
    # sources themselves are NOT inputs here: they live only in the
    # `skills-devshell/` sub-flake's lock, which this dev shell invokes at
    # RUNTIME (never as a root input), keeping this flake a leaf with zero skill
    # inputs.
    agent-skill-flake = {
      url = "github:nhooey/agent-skill-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-parts,
      systems,
      devshell,
      treefmt-nix,
      agent-skill-flake,
      ...
    }@inputs:
    let
      # Root-side wiring for the `skills-devshell/` sub-flake: the dev-shell
      # skill set (all skills-git skills plus nix-flakes/nix-garnix-ci from
      # skills-nix) is defined in the isolated `skills-devshell/` sub-flake and
      # invoked here at RUNTIME (not a root input), so this flake keeps zero
      # skill inputs and never drags the skill mesh into its lock.
      devshellSkills = agent-skill-flake.lib.devshellSkillsHook { };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;

      imports = [
        devshell.flakeModule
        treefmt-nix.flakeModule
      ];

      perSystem =
        {
          config,
          pkgs,
          lib,
          system,
          ...
        }:
        let
          gstack = pkgs.callPackage ./nix/gstack.nix { };
        in
        {
          packages = {
            inherit gstack;
            default = gstack;
          };

          checks = {
            # Refuses the build if bun.lock references any package name
            # listed in nix/compromised-packages.txt (Mini Shai-Hulud, etc.).
            # Runs on `nix flake check` so supply-chain regressions surface
            # without a full FOD rebuild.
            supply-chain = gstack.passthru.supplyChainCheck;
          };

          treefmt = {
            projectRootFile = "flake.nix";
            # Only nixfmt for now. Adding shfmt / prettier / etc. would force
            # opinions on consumers — opt those in deliberately in follow-up
            # PRs once excludes are dialled in.
            programs.nixfmt.enable = true;
            settings.global.excludes = [
              "**/*.lock"
            ];
          };

          devshells.default = {
            name = "nix-gstack";
            motd = ''
              {bold}{14}🥞 Entering nix-gstack dev shell{reset}
              Run {bold}menu{reset} to list available commands.
            '';
            packages = [
              pkgs.gh
              pkgs.git
              pkgs.jq
              pkgs.nix
              pkgs.ripgrep
            ];

            # Auto-reconcile the dev-shell skill set at project scope on
            # `nix develop`: every skills-git skill plus nix-flakes/
            # nix-garnix-ci from skills-nix, merged into one combination that a
            # single reconcile owner converges — declarative + idempotent. The
            # skills-devshell sub-flake's reconcile app is invoked at RUNTIME by
            # this hook (`nix run "$PRJ_ROOT/skills-devshell#reconcile"`), so the
            # skill sources never become root inputs.
            devshell.startup.install-skills.text = devshellSkills.startup;

            commands = [
              # ci
              {
                category = "ci";
                name = "check";
                help = "Run `nix flake check` (formatting + flake eval)";
                command = "nix flake check";
              }
              {
                category = "ci";
                name = "fmt";
                help = "Format every supported filetype via treefmt (Nix)";
                command = "nix fmt";
              }
              {
                category = "ci";
                name = "fmt-check";
                help = "Verify formatting without writing changes";
                command = "nix fmt -- --ci";
              }

              # update
              {
                category = "update";
                name = "update-flake";
                help = "Refresh every flake input to its latest revision";
                command = "nix flake update";
              }
            ]
            ++ devshellSkills.commands;
          };
        };
    };
}
