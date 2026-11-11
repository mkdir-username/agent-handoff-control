#!/usr/bin/env bash
# Removes agent-handoff-control hooks from ~/.claude/settings.json and deletes
# ~/.claude/handoff-control (hooks, rubrics, state and the verdict log).
set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "uninstall: 'jq' is required" >&2; exit 1; }

DEST="$HOME/.claude/handoff-control"
SETTINGS="$HOME/.claude/settings.json"

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"
  TMP=$(mktemp)
  jq --arg d "$DEST/hooks/" '
    if .hooks then
      .hooks |= with_entries(
        .value |= ( map(.hooks |= map(select((.command // "") | contains($d) | not)))
                    | map(select((.hooks | length) > 0)) ))
      | .hooks |= with_entries(select((.value | length) > 0))
    else . end
  ' "$SETTINGS" > "$TMP" || { rm -f "$TMP"; echo "uninstall: could not update $SETTINGS — nothing removed" >&2; exit 1; }
  mv "$TMP" "$SETTINGS"
fi

# DSH: remove only our Stop hook from the hook config; foreign hooks and their file stay.
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
DSH_HOOKS="${HANDOFF_DSH_HOOKS:-$DSH_HOME/agent-handoff-control.json}"
if [ -f "$DSH_HOOKS" ]; then
  DSH_CMD="bash \"$DEST/hooks/adapters/stop-handoff-control-dsh.sh\""
  cp "$DSH_HOOKS" "$DSH_HOOKS.bak-$(date +%Y%m%d%H%M%S)"
  TMP=$(mktemp)
  jq --arg c "$DSH_CMD" '
    .hooks = (.hooks // {})
    | .hooks.Stop = ((.hooks.Stop // [])
        | map(.hooks |= map(select(.command != $c)))
        | map(select((.hooks | length) > 0)))
    | .hooks |= with_entries(select((.value | length) > 0))
  ' "$DSH_HOOKS" > "$TMP" || { rm -f "$TMP"; echo "uninstall: could not update $DSH_HOOKS — DSH hook left in place" >&2; exit 1; }
  mv "$TMP" "$DSH_HOOKS"
  jq -e '.hooks | length == 0' "$DSH_HOOKS" >/dev/null 2>&1 && rm -f "$DSH_HOOKS" || true
fi

rm -rf "$DEST"
echo "agent-handoff-control removed. Restart the agent runtime (Claude Code / DSH)."
