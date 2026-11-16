# Usage: supply-chain-scan.sh PATTERNS LOCKFILE
#
# Fails, listing the matching lines, if LOCKFILE names any package in
# PATTERNS (one name per line, `#` comments and blank lines ignored). A
# match is a whole word in grep's sense, so `lightning` does not match
# `lightningcss`. Comments and blank lines are stripped before grep sees
# the list: grep treats an empty pattern as match-all. A PATTERNS or
# LOCKFILE that cannot be read fails the scan, since nothing was checked.
set -eu

patterns_file=$1
lockfile=$2

unreadable() {
  echo "ERROR: supply-chain scan cannot read $1. Refusing to build." >&2
  exit 2
}

[ -r "$patterns_file" ] || unreadable "$patterns_file"
[ -r "$lockfile" ] || unreadable "$lockfile"

# grep exits 1 when every line is a comment or blank: an empty list.
patterns=$(grep -v '^[[:space:]]*\(#\|$\)' "$patterns_file") ||
  [ $? -eq 1 ] || unreadable "$patterns_file"
if [ -z "$patterns" ]; then
  exit 0
fi

status=0
matches=$(printf '%s\n' "$patterns" | grep -wFf - "$lockfile") || status=$?
case $status in
  0)
    echo "" >&2
    echo "ERROR: $lockfile references known-compromised npm/PyPI packages:" >&2
    printf '%s\n' "$matches" | sed 's/^/  /' >&2
    echo "See nix/compromised-packages.txt. Refusing to build." >&2
    exit 1
    ;;
  1) ;;
  *) unreadable "$lockfile" ;;
esac
