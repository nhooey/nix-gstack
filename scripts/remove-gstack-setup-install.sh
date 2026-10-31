#!/usr/bin/env bash
# remove-gstack-setup-install: remove what `gstack-setup` installed outside the
# Nix store, after showing every path and asking first.
#
# `gstack-setup` (this flake's package) stages a mutable copy of gstack in
# $GSTACK_HOME and runs upstream `setup`, which installs into the Claude Code
# skills folder and settings. This script finds, and only after a yes at the
# terminal removes:
#
#   - skill entries named `gstack`, `_gstack-command` or `gstack-*` in the
#     skills folder that belong to $GSTACK_HOME: a symlink into it, or a
#     folder whose `.gstack-owned` marker names it. Anything else is kept.
#   - $GSTACK_HOME itself.
#   - hooks in settings.json tagged `_gstack_source`, which gstack's
#     settings-hook tool adds. settings.json is backed up first.
#   - the settings backups that tool writes (settings.json.bak.<date>-<time>.
#     <pid>.<random>) and its settings.json.bak-latest pointer.
#
# It keeps ~/.gstack, gstack's own state (config, history, analytics).
#
# Usage:
#   remove-gstack-setup-install [--gstack-home DIR] [--skills-dir DIR]
#                               [--settings FILE] [-h|--help]
#
#   --gstack-home DIR  gstack's staged copy (default: $GSTACK_HOME, else
#                      ~/.local/share/gstack)
#   --skills-dir DIR   Claude Code skills folder, symlinks resolved (default:
#                      ${CLAUDE_CONFIG_DIR:-~/.claude}/skills)
#   --settings FILE    Claude Code settings (default:
#                      ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json)
#
# Example:
#   nix run github:nhooey/nix-gstack#remove-gstack-setup-install

set -euo pipefail

claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
gstack_home="${GSTACK_HOME:-$HOME/.local/share/gstack}"
skills_dir="$claude_dir/skills"
settings="$claude_dir/settings.json"

print_help() {
  sed -n '/^# remove-gstack-setup-install:/,/^$/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

while [ $# -gt 0 ]; do
  case "$1" in
  --gstack-home)
    gstack_home="$2"
    shift 2
    ;;
  --skills-dir)
    skills_dir="$2"
    shift 2
    ;;
  --settings)
    settings="$2"
    shift 2
    ;;
  -h | --help)
    print_help
    exit 0
    ;;
  *)
    printf 'error: unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
  esac
done

# Compare against the physical paths, as setup wrote them.
gstack_home="${gstack_home%/}"
if [ -d "$skills_dir" ]; then
  skills_dir="$(realpath "$skills_dir")"
fi

paths=()
kept=()

# Skill entries that belong to this gstack home.
if [ -d "$skills_dir" ]; then
  for entry in "$skills_dir"/gstack "$skills_dir"/_gstack-command "$skills_dir"/gstack-*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    if [ -L "$entry" ]; then
      target="$(readlink "$entry")"
      case "$target" in
      "$gstack_home" | "$gstack_home"/*) paths+=("$entry") ;;
      *) kept+=("$entry (links to $target)") ;;
      esac
    elif [ -f "$entry/.gstack-owned" ] && [ "$(cat "$entry/.gstack-owned")" = "$gstack_home" ]; then
      paths+=("$entry")
    else
      kept+=("$entry (no .gstack-owned marker naming $gstack_home)")
    fi
  done
fi

skill_count=${#paths[@]}

if [ -d "$gstack_home" ]; then
  paths+=("$gstack_home")
fi

# Settings backups written by gstack's settings-hook tool.
settings_dir="$(dirname "$settings")"
settings_name="$(basename "$settings")"
backups=()
if [ -d "$settings_dir" ]; then
  while IFS= read -r -d '' backup; do
    backups+=("$backup")
  done < <(find "$settings_dir" -maxdepth 1 -type f \
    -name "$settings_name.bak.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].[0-9]*.[0-9]*" -print0)
fi
latest="$settings.bak-latest"
if [ -f "$latest" ]; then
  pointed="$(cat "$latest")"
  for backup in "${backups[@]}"; do
    if [ "$backup" = "$pointed" ]; then
      backups+=("$latest")
      break
    fi
  done
fi
paths+=("${backups[@]}")

# Hooks tagged by gstack in settings.json.
hook_sources=""
if [ -f "$settings" ]; then
  hook_sources="$(jq -r '[(.hooks // {}) | to_entries[] | .key as $event | .value[] | select(has("_gstack_source")) | "\($event): \(._gstack_source)"] | .[]' "$settings")"
fi

if [ ${#paths[@]} -eq 0 ] && [ -z "$hook_sources" ]; then
  echo "Nothing from gstack-setup to remove."
  exit 0
fi

echo "gstack home: $gstack_home"
echo "skills dir:  $skills_dir"
echo
echo "Will delete these ${#paths[@]} paths ($skill_count skill entries):"
printf '  %s\n' "${paths[@]}"
if [ -n "$hook_sources" ]; then
  echo
  echo "Will remove these gstack hooks from $settings (backed up first):"
  printf '%s\n' "$hook_sources" | sed 's/^/  /'
fi
if [ ${#kept[@]} -gt 0 ]; then
  echo
  echo "Will keep these, which don't belong to $gstack_home:"
  printf '  %s\n' "${kept[@]}"
fi
echo
echo "Keeps ~/.gstack (gstack's own config and history)."
echo

if [ ! -t 0 ]; then
  echo "error: not run from a terminal, so there is no one to ask; nothing deleted." >&2
  exit 1
fi
read -r -p "Delete all of the above? [y/N] " reply
case "$reply" in
y | Y | yes | YES) ;;
*)
  echo "Nothing deleted."
  exit 1
  ;;
esac

for path in "${paths[@]}"; do
  rm -r -- "$path"
done

if [ -n "$hook_sources" ]; then
  backup="$settings.before-remove-gstack-setup-install"
  cp -- "$settings" "$backup"
  tmp="$(mktemp "$settings_dir/.$settings_name.XXXXXX")"
  jq '
    if .hooks then
      .hooks |= (map_values(map(select(has("_gstack_source") | not)))
                 | with_entries(select(.value | length > 0)))
      | if .hooks == {} then del(.hooks) else . end
    else . end
  ' "$backup" >"$tmp"
  mv -- "$tmp" "$settings"
  echo "Removed gstack's hooks from $settings (previous copy: $backup)."
fi

echo "Deleted ${#paths[@]} paths."
