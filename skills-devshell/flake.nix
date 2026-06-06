{
  description = "nix-gstack dev-shell skill set — an isolated sub-flake invoked at RUNTIME by the root devShell, never a root input. The skill sources (all skills-git skills plus nix-flakes/nix-garnix-ci from skills-nix) live only in THIS flake's lock, so the root nix-gstack stays a leaf with zero skill inputs and transitive consumers never drag the skill mesh in.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";

    agent-skill-flake = {
      url = "github:nhooey/agent-skill-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Every input below this divider is a skill source.

    skills-git = {
      url = "github:nhooey/skills-git";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        agent-skill-flake.follows = "agent-skill-flake";
      };
    };

    skills-nix = {
      url = "github:nhooey/skills-nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-skills.follows = "agent-skill-flake";
        skills-git.follows = "skills-git";
      };
    };
  };

  outputs =
    {
      nixpkgs,
      agent-skill-flake,
      skills-git,
      skills-nix,
      ...
    }@inputs:
    agent-skill-flake.lib.mkDevshellSkillsFlake {
      inherit nixpkgs;
      systems = import inputs.systems;
      name = "nix-gstack-skills";
      sources = [
        { source = skills-git; }
        {
          source = skills-nix;
          skills = [
            "nix-flakes"
            "nix-garnix-ci"
          ];
        }
      ];
    };
}
