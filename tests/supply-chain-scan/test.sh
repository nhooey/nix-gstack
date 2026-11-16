# Usage: test.sh SCAN FIXTURES
#
# Runs the supply-chain scan against fixed lockfiles and fails on the
# first case whose outcome is not the expected one.
set -u

scan=$1
fixtures=$2
failures=0

expect() {
  want=$1 name=$2 patterns=$3 lockfile=$4
  if bash "$scan" "$patterns" "$lockfile" >stdout 2>stderr; then
    got=pass
  else
    got=fail
  fi
  if [ "$got" = "$want" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected the scan to $want, it did $got" >&2
    cat stderr >&2
    failures=$((failures + 1))
  fi
}

expect fail "rejects a lockfile that names a listed package" \
  "$fixtures/patterns.txt" "$fixtures/compromised.lock"
expect pass "accepts names that only contain a listed name" \
  "$fixtures/patterns.txt" "$fixtures/clean.lock"
expect pass "a list of only comments and blank lines matches nothing" \
  "$fixtures/comments-only.txt" "$fixtures/compromised.lock"

# The failure names the offending lockfile line, so whoever reads the
# build log can see which package tripped it.
bash "$scan" "$fixtures/patterns.txt" "$fixtures/compromised.lock" 2>stderr || true
if grep -qF '"@tanstack/history": ["@tanstack/history@1.161.9"' stderr; then
  echo "ok   the failure lists the matching line"
else
  echo "FAIL the failure lists the matching line; stderr was:" >&2
  cat stderr >&2
  failures=$((failures + 1))
fi

[ "$failures" -eq 0 ]
