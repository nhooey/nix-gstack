# Usage: supply-chain-scan.sh PATTERNS LOCKFILE
#
# Fails, listing the matching lines, if LOCKFILE names any package in
# PATTERNS (one name per line, `#` comments and blank lines ignored). A
# match is a whole word in grep's sense, so `lightning` does not match
# `lightningcss`. Comments and blank lines are stripped before grep sees
# the list: grep treats an empty pattern as match-all.
set -eu

patterns_file=$1
lockfile=$2

patterns=$(grep -v '^[[:space:]]*\(#\|$\)' "$patterns_file" || true)
if [ -z "$patterns" ]; then
  exit 0
fi

if matches=$(printf '%s\n' "$patterns" | grep -wFf - "$lockfile"); then
  echo "" >&2
  echo "ERROR: $lockfile references known-compromised npm/PyPI packages:" >&2
  printf '%s\n' "$matches" | sed 's/^/  /' >&2
  echo "See nix/compromised-packages.txt. Refusing to build." >&2
  exit 1
fi
