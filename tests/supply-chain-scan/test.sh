# Usage: test.sh SCAN FIXTURES
#
# Runs the supply-chain scan against fixed lockfiles and fails if any
# case's outcome, or its expected error message, is not the expected one.
set -u

scan=$1
fixtures=$2
failures=0

expect() {
  want=$1 name=$2 patterns=$3 lockfile=$4 says=${5:-}
  if bash "$scan" "$patterns" "$lockfile" >stdout 2>stderr; then
    got=pass
  else
    got=fail
  fi
  if [ -n "$says" ] && ! grep -qF "$says" stderr; then
    echo "FAIL $name: expected stderr to say: $says" >&2
    cat stderr >&2
    failures=$((failures + 1))
  elif [ "$got" = "$want" ]; then
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
expect pass "accepts a hyphenated sibling of a listed name" \
  "$fixtures/patterns.txt" "$fixtures/sibling.lock"
expect pass "a list of only comments and blank lines matches nothing" \
  "$fixtures/comments-only.txt" "$fixtures/compromised.lock"
# A scan that cannot read its inputs has checked nothing, so it fails.
# A directory stands in for an unreadable file, since root can read a
# file whatever its mode.
expect fail "a missing list fails the scan" \
  "$fixtures/missing.txt" "$fixtures/compromised.lock" "cannot read"
expect fail "an unreadable list fails the scan" \
  "$fixtures" "$fixtures/compromised.lock" "cannot read"
expect fail "a missing lockfile fails the scan" \
  "$fixtures/patterns.txt" "$fixtures/missing.lock" "cannot read"
expect fail "a missing lockfile fails the scan even with an empty list" \
  "$fixtures/comments-only.txt" "$fixtures/missing.lock" "cannot read"
expect fail "an unreadable lockfile fails the scan" \
  "$fixtures/patterns.txt" "$fixtures" "cannot read"
expect fail "an unreadable lockfile fails the scan even with an empty list" \
  "$fixtures/comments-only.txt" "$fixtures" "cannot read"
expect fail "rejects a lockfile with no packages" \
  "$fixtures/patterns.txt" "$fixtures/no-packages.lock" "lists no packages"
expect fail "rejects a lockfile with no packages even with an empty list" \
  "$fixtures/comments-only.txt" "$fixtures/no-packages.lock" "lists no packages"
expect fail "rejects a lockfile it cannot parse" \
  "$fixtures/patterns.txt" "$fixtures/truncated.lock" "cannot parse"
expect fail "rejects a lockfile it cannot parse even with an empty list" \
  "$fixtures/comments-only.txt" "$fixtures/truncated.lock" "cannot parse"
expect fail "rejects a package entry without a name@version" \
  "$fixtures/patterns.txt" "$fixtures/no-name.lock" "without a name@version"
expect fail "rejects an empty package id" \
  "$fixtures/patterns.txt" "$fixtures/empty-id.lock" "without a name@version"
expect fail "rejects a package id without a version" \
  "$fixtures/patterns.txt" "$fixtures/no-version.lock" "without a name@version"
expect fail "rejects an npm alias of a listed package" \
  "$fixtures/patterns.txt" "$fixtures/npm-alias.lock" \
  "  lightning-alias@npm:lightning@1.0.0"

# A resolution can hold an `@` of its own, which must not end the name.
expect fail "rejects a listed package resolved from a tarball URL" \
  "$fixtures/patterns.txt" "$fixtures/tarball-url.lock" \
  "  @tanstack/history@https://"
expect fail "rejects a listed package resolved from git+ssh" \
  "$fixtures/patterns.txt" "$fixtures/git-ssh.lock" \
  "  lightning@git+ssh://git@"

# The scan fails when it reads no packages even if bun exits 0 without
# saying so: a stub bun that prints nothing stands in for that.
mkdir -p silent-bun
printf '#!/bin/sh\nexit 0\n' >silent-bun/bun
chmod u+x silent-bun/bun
PATH="$PWD/silent-bun:$PATH" expect fail \
  "a lockfile that yields no packages fails the scan" \
  "$fixtures/patterns.txt" "$fixtures/compromised.lock" \
  "no packages read from"

# The failure names the offending package and version, so whoever reads
# the build log can see which package tripped it.
bash "$scan" "$fixtures/patterns.txt" "$fixtures/compromised.lock" 2>stderr || true
if grep -qxF '  @tanstack/history@1.161.9' stderr; then
  echo "ok   the failure lists the matching package"
else
  echo "FAIL the failure lists the matching package; stderr was:" >&2
  cat stderr >&2
  failures=$((failures + 1))
fi

[ "$failures" -eq 0 ]
