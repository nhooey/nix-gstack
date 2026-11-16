# Usage: test.sh SKILLS SKILL-NAME...
#
# Checks the rendered skills tree that the agent-skill-garrytan-* packages
# are cut from: each packaged skill has its own rendered SKILL.md, no
# SKILL.md sends the agent to ~/.claude/skills/gstack (nothing installs
# a `gstack` folder there), and /autoplan reads the other reviews from
# this tree in the store.
set -u

skills=$1
shift
failures=0

fail() {
  echo "FAIL $*" >&2
  failures=$((failures + 1))
}

for name in "$@"; do
  skill_md=$skills/$name/SKILL.md
  if [ ! -f "$skill_md" ] || [ -L "$skill_md" ]; then
    fail "$name: SKILL.md is missing or still links to the unrendered original"
    continue
  fi
  if grep -nE '(~|\$HOME|\$\{HOME\})/\.claude/skills/gstack' "$skill_md" >home-refs; then
    fail "$name: SKILL.md refers to ~/.claude/skills/gstack:"
    sed 's/^/  /' home-refs >&2
  fi
done
echo "checked $# rendered skills"

for review in plan-ceo-review plan-design-review plan-eng-review plan-devex-review; do
  if ! grep -qF "$skills/$review/SKILL.md" "$skills/autoplan/SKILL.md"; then
    fail "autoplan: does not read $review from $skills"
  fi
done

[ "$failures" -eq 0 ]
