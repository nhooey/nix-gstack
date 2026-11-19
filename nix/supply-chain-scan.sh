# Usage: supply-chain-scan.sh PATTERNS LOCKFILE
#
# Fails, listing each matching `name@version`, if the bun.lock LOCKFILE
# resolves any package named in PATTERNS (one name per line, `#` comments
# and blank lines ignored). bun parses the lockfile (JSONC, with trailing
# commas), and a package matches only when its name equals a listed name,
# so `@tanstack/history` matches neither `@tanstack/history-plugin` nor
# `@tanstack/historyx`. A PATTERNS or LOCKFILE that cannot be read, and a
# lockfile bun cannot parse or with no packages, fail the scan, since
# nothing was checked. Needs `bun` on PATH.
set -eu

patterns_file=$1
lockfile=$2

unreadable() {
  echo "ERROR: supply-chain scan cannot read $1. Refusing to build." >&2
  exit 2
}

[ -r "$patterns_file" ] || unreadable "$patterns_file"
[ -f "$lockfile" ] && [ -r "$lockfile" ] || unreadable "$lockfile"

# One `name<TAB>name@version` line per package: the name is everything
# before the first `@` after the first character of the entry's first
# element. An npm name holds `@` only as a scope's first character, so a
# scoped name keeps its leading `@`, and a resolution that holds `@` (a
# tarball URL, `git+ssh://git@…`) stays out of the name. An entry with
# no such `@` fails the scan, and an `npm:` alias adds a line for the
# package it aliases.
# shellcheck disable=SC2016 # the JavaScript is single-quoted on purpose
packages=$(bun -e '
  const path = process.argv[1];
  let lock;
  try {
    lock = Bun.JSONC.parse(require("fs").readFileSync(path, "utf8"));
  } catch (e) {
    console.error(`ERROR: cannot parse ${path}: ${e.message}`);
    process.exit(1);
  }
  const entries = Object.values((lock && lock.packages) || {});
  if (entries.length === 0) {
    console.error(`ERROR: ${path} lists no packages; refusing to pass it unread.`);
    process.exit(1);
  }
  for (const entry of entries) {
    const id = Array.isArray(entry) ? entry[0] : undefined;
    const at = typeof id === "string" ? id.indexOf("@", 1) : -1;
    if (at < 1) {
      console.error(`ERROR: ${path} has a package entry without a name@version.`);
      process.exit(1);
    }
    console.log(`${id.slice(0, at)}\t${id}`);
    // An alias `alias@npm:real@1.0.0` is refused when either name is listed.
    const rest = id.slice(at + 1);
    if (rest.startsWith("npm:")) {
      const real = rest.slice(4);
      const realAt = real.indexOf("@", 1);
      console.log(`${realAt > 0 ? real.slice(0, realAt) : real}\t${id}`);
    }
  }
' "$lockfile")
if [ -z "$packages" ]; then
  echo "ERROR: no packages read from $lockfile. Refusing to build." >&2
  exit 1
fi

# grep exits 1 when every line is a comment or blank: an empty list.
patterns=$(grep -v '^[[:space:]]*\(#\|$\)' "$patterns_file") ||
  [ $? -eq 1 ] || unreadable "$patterns_file"
if [ -z "$patterns" ]; then
  exit 0
fi

matches=$(
  awk -F '\t' '
    NR == FNR { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); listed[$0] = 1; next }
    $1 in listed { print $2 }
  ' <(printf '%s\n' "$patterns") <(printf '%s\n' "$packages")
)
if [ -n "$matches" ]; then
  echo "" >&2
  echo "ERROR: $lockfile references known-compromised npm/PyPI packages:" >&2
  printf '%s\n' "$matches" | sed 's/^/  /' >&2
  echo "See nix/compromised-packages.txt. Refusing to build." >&2
  exit 1
fi
