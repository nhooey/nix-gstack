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

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # `agent-skill-flake` is the builder library, not a skill — it provides the
    # `flakeModules.devshellSkills` flake-parts module that wires the dev-shell
    # skill set in below. That module bundles numtide/devshell, so this flake
    # needs no `devshell` input of its own. The skill sources themselves are NOT
    # inputs here: they live only in the `skills-devshell/` sub-flake's lock,
    # which this dev shell invokes at RUNTIME (never as a root input), keeping
    # this flake a leaf with zero skill inputs.
    agent-skill-flake = {
      url = "github:nhooey/agent-skill-flake";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.systems.follows = "systems";
      inputs.flake-parts.follows = "flake-parts";
      inputs.treefmt-nix.follows = "treefmt-nix";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-parts,
      systems,
      treefmt-nix,
      ...
    }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;

      imports = [
        # Bundles numtide/devshell + the whole dev-shell skills convention
        # (motd, install-skills startup, the ci/dev/maintenance command trio,
        # and the reap-skills/update-skills-devshell pair). Configured via the
        # `agent-skill-flake.devshellSkills` options block below.
        inputs.agent-skill-flake.flakeModules.devshellSkills
        treefmt-nix.flakeModule
      ];

      # nix-gstack keeps its custom motd (the pancake banner); the module's
      # generated banner is overridden by passing `motd` here.
      agent-skill-flake.devshellSkills = {
        name = "nix-gstack";
        motd = ''
          {bold}{14}🥞 Entering nix-gstack dev shell{reset}
          Run {bold}menu{reset} to list available commands.
        '';
      };

      perSystem =
        { pkgs, ... }:
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

          # The devshellSkills module (imported above) supplies this devShell's
          # name, motd, the install-skills startup, the ci/dev/maintenance
          # command trio (check / fmt / update-flake), and the skills commands
          # (reap-skills / update-skills-devshell). Only nix-gstack-specific
          # packages and commands are set here; both are list options, so they
          # merge onto the module's rather than replacing them.
          devshells.default = {
            packages = [
              pkgs.gh
              pkgs.git
              pkgs.jq
              pkgs.nix
              pkgs.ripgrep
            ];

            commands = [
              {
                category = "ci";
                name = "fmt-check";
                help = "Verify formatting without writing changes";
                command = "nix fmt -- --ci";
              }
            ];
          };
        };
    };
}
