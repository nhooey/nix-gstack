# nix-gstack

Nix flake providing [gstack](https://github.com/nhooey/gstack) packaging,
intended to be pulled into an NUR Packages repository.

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
    let system = "aarch64-darwin"; in {
      packages.${system}.gstack = nix-gstack.packages.${system}.gstack;
    };
}
```

### Installing chosen skills with agent-skill-flake

Each skill is also a package, `agent-skill-garrytan-<name>`, rendered so that
the paths it would take from `~/.claude/skills/gstack` point into the Nix store
instead. No `gstack` folder is installed, and nothing is written outside Nix
except gstack's own runtime state in `~/.gstack`. List nix-gstack as a source
of agent-skill-flake's `mkDevshellSkillsFlake` and pick skills by name:

```nix
{
  source = nix-gstack;
  skills = [ "plan-eng-review" "investigate" ];
  prefix = "gstack"; # installs /gstack-plan-eng-review and /gstack-investigate
}
```

Or run it directly:

```sh
nix run github:nhooey/nix-gstack
# stages gstack into ~/.local/share/gstack and runs its setup script
```
