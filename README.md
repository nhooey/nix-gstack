# nix-gstack

Nix flake providing [gstack](https://github.com/nhooey/gstack) packaging,
intended to be pulled into an NUR Packages repository.

[![Garnix CI](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fnhooey%2Fnix-gstack%3Fbranch%3Dmaster&label=Garnix%20CI)](https://garnix.io/repo/nhooey/nix-gstack)

## What's here

- `flake.nix` — flake-parts skeleton wiring up
  [devshell](https://github.com/numtide/devshell) and
  [treefmt-nix](https://github.com/numtide/treefmt-nix) (nixfmt only)
- `nix/gstack.nix` — `packages.<sys>.gstack` (also exposed as `default`):
  a hermetic build. A fixed-output `node_modules` derivation runs
  `bun install --frozen-lockfile --ignore-scripts` with network, then
  `bun run build` compiles the `browse` / `design` / `make-pdf` binaries
  inside the Nix sandbox (Chromium from `pkgs.playwright-driver`, no
  runtime download). The output is a `gstack-setup` launcher that copies
  the prebuilt tree into `$GSTACK_HOME` (default `~/.local/share/gstack`)
  and runs the upstream `setup` with `GSTACK_PREBUILT=1`, so activation is
  offline and only does skill registration
- `garnix.yaml` — [Garnix CI](https://garnix.io) builds
  `packages.x86_64-linux.*`, `checks.x86_64-linux.*`, and
  `devShells.x86_64-linux.default`. Other arches are not built yet — add
  their rows when ready to expand the matrix

The build is hermetic: `bun install` and `bun build --compile` run inside
Nix, gated by a per-system `nodeModulesHash` table in `nix/gstack.nix`.
Bumping the upstream rev or `bun.lock` means re-pinning that hash — see
the header comment in `nix/gstack.nix` for the workflow. A curated
`nix/compromised-packages.txt` is scanned against `bun.lock` (wired into
`nix flake check` as `checks.<sys>.supply-chain`) and refuses the build
on a known-compromised dependency.

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
