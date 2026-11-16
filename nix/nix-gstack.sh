# nix-gstack: maintenance commands for this repository's gstack package.
#
# Sourcing this file defines its functions without running anything;
# tests/nix-gstack does that to test the argument parsing and the edits
# to nix/gstack.nix.

# The `lib.fakeHash` value: a hash no fetch can match, so the build's
# mismatch error reports the real one.
fake_hash="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
upstream_url="https://github.com/garrytan/gstack"

usage() {
  cat <<'EOF'
Usage: nix-gstack [-h|--help] COMMAND [OPTION...]

Commands:
  pin     Re-pin the gstack source and its node_modules hash in nix/gstack.nix

Run `nix-gstack COMMAND --help` for a command's options.
EOF
}

pin_usage() {
  cat <<'EOF'
Usage: nix-gstack pin [--rev REV | --node-modules-only] [--system SYSTEM]

Points nix/gstack.nix at an upstream gstack commit and re-pins the hashes
that depend on it: src.hash, then the SYSTEM entry of nodeModulesHash.
Each hash comes from the mismatch error of a build against a fake hash.
On failure nix/gstack.nix is restored as it was.

Options:
  --rev REV             upstream commit to pin (default: upstream HEAD)
  --node-modules-only   keep src as it is; re-pin only nodeModulesHash,
                        e.g. after a bun or nixpkgs bump, or for a new SYSTEM
  --system SYSTEM       nodeModulesHash entry to pin (default: this machine's
                        system); a missing entry is added
  -h, --help            show this help
EOF
}

die_usage() {
  echo "nix-gstack: $1" >&2
  echo "Run \`nix-gstack --help\` for usage." >&2
  exit 2
}

# Sets pin_rev, pin_system and pin_node_modules_only from pin's arguments.
parse_pin_args() {
  pin_rev=""
  pin_system=""
  pin_node_modules_only=0
  while [ $# -gt 0 ]; do
    case $1 in
      --rev)
        [ $# -ge 2 ] || die_usage "pin: --rev needs a value"
        pin_rev=$2
        shift 2
        ;;
      --rev=*)
        pin_rev=${1#--rev=}
        shift
        ;;
      --system)
        [ $# -ge 2 ] || die_usage "pin: --system needs a value"
        pin_system=$2
        shift 2
        ;;
      --system=*)
        pin_system=${1#--system=}
        shift
        ;;
      --node-modules-only)
        pin_node_modules_only=1
        shift
        ;;
      -h | --help)
        pin_usage
        exit 0
        ;;
      *) die_usage "pin: unknown argument: $1" ;;
    esac
  done
  if [ -n "$pin_rev" ] && [ "$pin_node_modules_only" -eq 1 ]; then
    die_usage "pin: --rev and --node-modules-only exclude each other"
  fi
  if [ -n "$pin_rev" ] && ! printf '%s' "$pin_rev" | grep -Eq '^[0-9a-f]{40}$'; then
    die_usage "pin: --rev must be a full 40-character commit hash"
  fi
}

# set_src FILE REV HASH: rewrites `rev` and `hash` in FILE's
# `src = pkgs.fetchFromGitHub { … };` block. Fails if either is missing.
set_src() {
  awk -v rev="$2" -v hash="$3" '
    /^[[:space:]]*src = pkgs\.fetchFromGitHub \{/ { in_src = 1 }
    in_src && /^[[:space:]]*rev = "/ { sub(/"[^"]*"/, "\"" rev "\""); done_rev = 1 }
    in_src && /^[[:space:]]*hash = "/ { sub(/"[^"]*"/, "\"" hash "\""); done_hash = 1 }
    in_src && /^[[:space:]]*\};/ { in_src = 0 }
    { print }
    END { if (!done_rev || !done_hash) exit 1 }
  ' "$1" >"$1.tmp" || {
    rm -f "$1.tmp"
    echo "nix-gstack: no src rev and hash found in $1" >&2
    return 1
  }
  mv "$1.tmp" "$1"
}

# set_node_modules_hash FILE SYSTEM HASH: sets SYSTEM's entry in FILE's
# `nodeModulesHash` table, adding the entry if it is missing.
set_node_modules_hash() {
  awk -v sys="$2" -v hash="$3" '
    /^[[:space:]]*nodeModulesHash =/ { in_table = 1 }
    in_table && index($0, "\"" sys "\" = \"") {
      sub(/= "[^"]*"/, "= \"" hash "\""); done = 1
    }
    in_table && /^[[:space:]]*\}/ {
      if (!done) {
        indent = $0; sub(/\}.*/, "", indent)
        print indent "  \"" sys "\" = \"" hash "\";"
        done = 1
      }
      in_table = 0
    }
    { print }
    END { if (!done) exit 1 }
  ' "$1" >"$1.tmp" || {
    rm -f "$1.tmp"
    echo "nix-gstack: no nodeModulesHash table found in $1" >&2
    return 1
  }
  mv "$1.tmp" "$1"
}

# Reads a build log on stdin and prints the hash from the last
# fixed-output mismatch in it (the `got:` line).
parse_got_hash() {
  sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[A-Za-z0-9+/]*=*\).*/\1/p' | tail -n 1
}

# fetch_hash ROOT SYSTEM ATTR: builds ROOT's ATTR of the default package
# for SYSTEM, which must fail on a fake hash, and prints the real hash.
fetch_hash() {
  local root=$1 system=$2 attr=$3 log hash
  local -a override=()
  if [ "$system" != "$(current_system)" ]; then
    # The flake lists only the systems it has hashes for.
    override=(--override-input systems "github:nix-systems/$system")
  fi
  log=$(mktemp)
  echo "nix-gstack: building $attr for $system to learn its hash" >&2
  if nix build --no-link "${override[@]}" "$root#packages.$system.default.$attr" 2>"$log"; then
    rm -f "$log"
    echo "nix-gstack: $attr built against the fake hash; nothing to learn" >&2
    return 1
  fi
  hash=$(parse_got_hash <"$log")
  if [ -z "$hash" ]; then
    cat "$log" >&2
    rm -f "$log"
    echo "nix-gstack: the $attr build failed without a hash mismatch" >&2
    return 1
  fi
  rm -f "$log"
  printf '%s\n' "$hash"
}

current_system() {
  nix eval --impure --raw --expr builtins.currentSystem
}

cmd_pin() {
  parse_pin_args "$@"
  local root file backup rev system hash
  root=$(git rev-parse --show-toplevel)
  file=$root/nix/gstack.nix
  system=${pin_system:-$(current_system)}

  backup=$(mktemp)
  cp "$file" "$backup"
  # Leaves no fake hash behind if a step fails. The paths are expanded
  # now: the locals are gone by the time the EXIT trap runs.
  # shellcheck disable=SC2064
  trap "cp $(printf %q "$backup") $(printf %q "$file"); rm -f $(printf %q "$backup")" EXIT

  if [ "$pin_node_modules_only" -eq 0 ]; then
    rev=${pin_rev:-$(git ls-remote "$upstream_url" HEAD | cut -f1)}
    [ -n "$rev" ] || {
      echo "nix-gstack: could not read upstream HEAD from $upstream_url" >&2
      return 1
    }
    set_src "$file" "$rev" "$fake_hash"
    hash=$(fetch_hash "$root" "$system" src)
    set_src "$file" "$rev" "$hash"
    echo "nix-gstack: src pinned to $rev ($hash)" >&2
  fi

  set_node_modules_hash "$file" "$system" "$fake_hash"
  hash=$(fetch_hash "$root" "$system" nodeModules)
  set_node_modules_hash "$file" "$system" "$hash"
  echo "nix-gstack: nodeModulesHash.$system pinned to $hash" >&2

  trap - EXIT
  rm -f "$backup"
  echo "nix-gstack: done; run \`check\` to build and test the result" >&2
}

main() {
  [ $# -gt 0 ] || {
    usage >&2
    exit 2
  }
  case $1 in
    -h | --help) usage ;;
    pin)
      shift
      cmd_pin "$@"
      ;;
    *) die_usage "unknown command: $1" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
