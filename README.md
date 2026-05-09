# nix-gstack

Nix flake providing [gstack](https://github.com/nhooey/gstack) packaging,
intended to be pulled into an NUR Packages repository.

[![Garnix CI](https://garnix.io/api/badges/nhooey/nix-gstack?branch=master)](https://garnix.io/repo/nhooey/nix-gstack)

## What's here

- `flake.nix` — flake-parts skeleton wiring up
  [devshell](https://github.com/numtide/devshell) and
  [treefmt-nix](https://github.com/numtide/treefmt-nix) (nixfmt only)
- `nix/gstack.nix` — `packages.<sys>.gstack` (also exposed as `default`):
  ships the gstack source tree plus a `gstack-setup` launcher that stages
  it into `$GSTACK_HOME` (default `~/.local/share/gstack`) and runs the
  upstream `setup` script
- `garnix.yaml` — [Garnix CI](https://garnix.io) builds `checks.*`,
  `devShells.*.default`, and `packages.*.gstack` across `x86_64-linux`,
  `aarch64-linux`, `x86_64-darwin`, `aarch64-darwin`

The package is runtime-resolved, not hermetic: the upstream `setup` runs
`bun install` and `bun build --compile`, both of which need network access
that a `nix build` sandbox doesn't provide. A future revision can swap to
a fixed-output `bun install` once we settle on a stable approach.

## Dev shell

```sh
nix develop
menu        # list available commands
check       # nix flake check
fmt         # nix fmt (nixfmt)
fmt-check   # verify formatting without writing
update-flake
```

## Consuming from another flake

```nix
{
  inputs.nix-gstack.url = "github:nhooey/nix-gstack";

  outputs = { self, nixpkgs, nix-gstack, ... }:
    let system = "x86_64-linux"; in {
      packages.${system}.gstack = nix-gstack.packages.${system}.gstack;
    };
}
```

Or run it directly:

```sh
nix run github:nhooey/nix-gstack
# stages gstack into ~/.local/share/gstack and runs its setup script
```
