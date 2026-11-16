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

    # aarch64-darwin only: the node_modules hash for gstack 088bfc5 has been
    # computed only there. Override this input with github:nix-systems/default
    # (or another nix-systems list) once nix/gstack.nix has the other hashes.
    systems.url = "github:nix-systems/aarch64-darwin";

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

      # nix-gstack's own motd (the pancake banner), which replaces the
      # module's generated banner.
      agent-skill-flake.devshellSkills = {
        name = "nix-gstack";
        motd = ''
          {bold}{14}🥞 Entering nix-gstack dev shell{reset}
          Run {bold}menu{reset} to list available commands.
        '';
      };

      perSystem =
        { pkgs, system, ... }:
        let
          inherit (pkgs) lib;
          gstack = pkgs.callPackage ./nix/gstack.nix { };
          inherit (gstack.passthru) skills src;

          # Every upstream skill: a top-level folder with a SKILL.md template,
          # except these. The root `gstack` skill routes to all the others,
          # and a consumer installs only the ones it picks; `claude-code` and
          # `connect-chrome` have templates that render nothing for Claude Code.
          notRendered = [
            "claude-code"
            "connect-chrome"
            "gstack"
          ];
          skillNames = lib.filter (
            name: !lib.elem name notRendered && builtins.pathExists "${src}/${name}/SKILL.md.tmpl"
          ) (lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir src)));

          # One `agent-skill-garrytan-<name>` package per skill, from its
          # rendered folder, so an agent-skill-flake consumer can list nix-gstack
          # as a source and pick skills by name, with a `prefix` if it wants one.
          skillPackages = lib.foldl' (
            acc: name:
            acc
            //
              lib.filterAttrs (key: _: lib.hasPrefix "agent-skill-" key)
                (inputs.agent-skill-flake.lib.mkSkillFlake {
                  inherit nixpkgs;
                  skillName = name;
                  source.owner = "garrytan";
                  src = "${skills}/${name}";
                  systems = [ system ];
                  description = "gstack skill: ${name}";
                  inherit (gstack.passthru.gstack) version;
                }).packages.${system}
          ) { } skillNames;

          # The repository's maintenance tool, from nix/nix-gstack.sh.
          nix-gstack = pkgs.writeShellApplication {
            name = "nix-gstack";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.gawk
              pkgs.git
              pkgs.gnugrep
              pkgs.gnused
              pkgs.nix
            ];
            text = builtins.readFile ./nix/nix-gstack.sh;
          };
        in
        {
          packages = skillPackages // {
            inherit gstack;
            default = gstack;
          };

          checks = {
            # Refuses the build if bun.lock references any package name
            # listed in nix/compromised-packages.txt (Mini Shai-Hulud, etc.).
            # Runs on `nix flake check` so supply-chain regressions surface
            # without a full FOD rebuild.
            supply-chain = gstack.passthru.supplyChainCheck;

            # The scan behind `supply-chain` rejects a listed name, and only
            # whole names, and fails on inputs it cannot read: fixture
            # lockfiles in tests/supply-chain-scan.
            supply-chain-scan = pkgs.runCommand "supply-chain-scan-test" { } ''
              bash ${./tests/supply-chain-scan/test.sh} \
                ${./nix/supply-chain-scan.sh} ${./tests/supply-chain-scan/fixtures}
              touch $out
            '';

            # nix-gstack's argument parsing and its edits to nix/gstack.nix.
            nix-gstack = pkgs.runCommand "nix-gstack-test" { } ''
              bash ${./tests/nix-gstack/test.sh} ${./nix/nix-gstack.sh} ${./nix/gstack.nix}
              touch $out
            '';

            # Every packaged skill is rendered to point at the store, not at
            # ~/.claude/skills/gstack.
            skills-render = pkgs.runCommand "skills-render-test" { } ''
              bash ${./tests/skills-render/test.sh} ${skills} ${lib.escapeShellArgs skillNames}
              touch $out
            '';

            # `nix flake check` only evaluates packages; this builds them all,
            # so a failed upstream patch (--replace-fail) or a broken skill
            # package fails the check.
            packages = pkgs.linkFarmFromDrvs "nix-gstack-packages" (
              lib.attrValues skillPackages
              ++ [
                gstack
                nix-gstack
              ]
            );
          };

          treefmt = {
            projectRootFile = "flake.nix";
            # Only nixfmt: shfmt, prettier and the like would force opinions
            # on consumers, so each needs its excludes worked out before it
            # is enabled.
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
              {
                category = "maintenance";
                package = nix-gstack;
                help = "Re-pin gstack's source and node_modules hashes (nix-gstack pin)";
              }
            ];
          };
        };
    };
}
