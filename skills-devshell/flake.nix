{
  description = "nix-gstack dev-shell skill set — an isolated sub-flake invoked at RUNTIME by the root devShell, never a root input. The skill sources live only in THIS flake's lock, so the root nix-gstack stays a leaf with zero skill inputs and transitive consumers never drag the skill mesh in.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";

    # The builder lib; it carries no skill inputs.
    agent-skill-flake = {
      url = "github:nhooey/agent-skill-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # skillspkgs' per-family skill combinations. It follows `nixpkgs` but not
    # `agent-skill-flake`, so its sources keep their own compatible builder.
    skillspkgs-combinations = {
      url = "github:nhooey/skillspkgs?dir=sources/combinations";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      agent-skill-flake,
      ...
    }@inputs:
    agent-skill-flake.lib.mkDevshellSkillsFlake {
      inherit nixpkgs;
      systems = import inputs.systems;
      name = "nix-gstack-skills";
      sources = [
        # nix-gstack is in the skill-packaging family; its combination is the
        # whole skill set, with no additions.
        { source = inputs.skillspkgs-combinations.combinations.skill-packaging; }
      ];
    };
}
