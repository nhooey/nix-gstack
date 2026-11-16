# nix-gstack

A Nix flake packaging [gstack](https://github.com/garrytan/gstack): a hermetic build of its binaries in `nix/gstack.nix`, and one `agent-skill-garrytan-<name>` package per gstack skill for agent-skill-flake consumers. The build is pinned by a per-system `nodeModulesHash` table, computed only for `aarch64-darwin`, the one system the flake builds for.

## Build and test

- `nix develop`: the dev shell, with the `check`, `fmt`, `fmt-check` and `update-flake` commands, and the project's skills installed into `.agents/skills/` from the `skills-devshell/` sub-flake.
- `nix build`: builds `gstack`, the default package.
- `nix flake check`: runs the supply-chain check, which refuses a `bun.lock` naming any package in `nix/compromised-packages.txt`; the tests under `tests/`, one directory per check; a build of every package; and fails on any file `nix fmt` would change.
- `nix fmt`: formats every Nix file with nixfmt.
