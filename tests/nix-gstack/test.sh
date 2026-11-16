# Usage: test.sh NIX-GSTACK GSTACK-NIX
#
# Tests nix-gstack's argument parsing and its edits to nix/gstack.nix,
# by sourcing the script so that nothing reaches the network or Nix.
# GSTACK-NIX is the real nix/gstack.nix, so a change to its layout that
# the edits no longer match fails here. Writes scratch files to the
# current directory.
set -u

tool=$1
gstack_nix=$2
failures=0

ok() { echo "ok   $*"; }
fail() {
  echo "FAIL $*" >&2
  failures=$((failures + 1))
}
check() {
  name=$1
  shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}

# shellcheck source=/dev/null
. "$tool"

# expect_exit STATUS NAME ARG...: runs main with ARG... in a subshell.
expect_exit() {
  want=$1 name=$2
  shift 2
  (main "$@") >stdout 2>stderr
  got=$?
  if [ "$got" -eq "$want" ]; then ok "$name"; else
    fail "$name: exit status $got, expected $want"
    cat stderr >&2
  fi
}

expect_exit 0 "--help exits 0" --help
check "--help lists the pin command" grep -q '^  pin ' stdout
expect_exit 2 "no command is a usage error"
expect_exit 2 "an unknown command is a usage error" frobnicate
expect_exit 0 "pin --help exits 0" pin --help
for option in --rev --node-modules-only --system --help; do
  check "pin --help lists $option" grep -q -- "$option" stdout
done
expect_exit 2 "pin rejects an unknown option" pin --bogus
expect_exit 2 "pin --rev needs a value" pin --rev
expect_exit 2 "pin --rev needs a full commit hash" pin --rev 088bfc5
expect_exit 2 "pin --rev and --node-modules-only exclude each other" \
  pin --rev 088bfc5914f8001a3d49b3a0c35d6f7cb800268c --node-modules-only

rev=0123456789abcdef0123456789abcdef01234567
parse_pin_args --rev="$rev" --system x86_64-linux
check "pin parses --rev= and --system" \
  [ "$pin_rev|$pin_system|$pin_node_modules_only" = "$rev|x86_64-linux|0" ]
parse_pin_args --node-modules-only
check "pin parses --node-modules-only" \
  [ "$pin_rev|$pin_system|$pin_node_modules_only" = "||1" ]

added_lines() { diff "$gstack_nix" gstack.nix | grep -c '^>'; }

cp "$gstack_nix" gstack.nix
chmod u+w gstack.nix
set_src gstack.nix "$rev" sha256-src=
check "set_src rewrites src's rev" grep -qF "rev = \"$rev\";" gstack.nix
check "set_src rewrites src's hash" grep -qF 'hash = "sha256-src=";' gstack.nix
check "set_src changes only those two lines" [ "$(added_lines)" -eq 2 ]

cp "$gstack_nix" gstack.nix
set_node_modules_hash gstack.nix aarch64-darwin sha256-new=
check "set_node_modules_hash replaces an entry" \
  grep -qF '"aarch64-darwin" = "sha256-new=";' gstack.nix
check "set_node_modules_hash changes only that line" [ "$(added_lines)" -eq 1 ]

set_node_modules_hash gstack.nix x86_64-linux sha256-linux=
added=$(grep -F '"x86_64-linux" = "sha256-linux=";' gstack.nix)
existing=$(grep -F '"aarch64-darwin" = "sha256-new=";' gstack.nix)
check "set_node_modules_hash adds a missing entry" [ -n "$added" ]
same_indent=no
[ -n "$added" ] && [ "${added%%\"*}" = "${existing%%\"*}" ] && same_indent=yes
check "the added entry has the existing entry's indent" [ "$same_indent" = yes ]

printf 'let x = 1; in x\n' >other.nix
check "set_src fails on a file without src" \
  bash -c '. "$1"; ! set_src other.nix "$2" sha256-x= 2>/dev/null' _ "$tool" "$rev"
check "a failed edit leaves the file alone" grep -qx 'let x = 1; in x' other.nix

got=$(
  parse_got_hash <<'LOG'
error: hash mismatch in fixed-output derivation '/nix/store/x-gstack-node-modules.drv':
         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            got:    sha256-ZMbFJNhbZ39my5hn9Sxow6CrjUIpuVauQacovZvlLZI=
LOG
)
check "parse_got_hash reads the got: line" \
  [ "$got" = sha256-ZMbFJNhbZ39my5hn9Sxow6CrjUIpuVauQacovZvlLZI= ]
got=$(echo 'error: builder failed' | parse_got_hash)
check "parse_got_hash prints nothing without a mismatch" [ -z "$got" ]

# cmd_pin end to end, with git and the Nix builds stubbed out: a stub
# fetch_hash returns a fixed hash, or fails like a broken build.
mkdir -p repo/nix
cp "$gstack_nix" repo/nix/gstack.nix
chmod u+w repo/nix/gstack.nix
git() { echo "$PWD/repo"; }
current_system() { echo aarch64-darwin; }
fetch_hash() { echo "sha256-$3="; }
(cmd_pin --rev "$rev") 2>/dev/null
check "pin writes the learned src hash" \
  grep -qF 'hash = "sha256-src=";' repo/nix/gstack.nix
check "pin writes the learned nodeModulesHash" \
  grep -qF '"aarch64-darwin" = "sha256-nodeModules=";' repo/nix/gstack.nix

cp "$gstack_nix" repo/nix/gstack.nix
fetch_hash() { [ "$3" = src ] && echo sha256-src= || return 1; }
(set -e; cmd_pin --rev "$rev") 2>/dev/null
check "pin fails when a build does" [ $? -ne 0 ]
check "a failed pin restores nix/gstack.nix" diff -q "$gstack_nix" repo/nix/gstack.nix

[ "$failures" -eq 0 ]
