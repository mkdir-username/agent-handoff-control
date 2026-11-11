#!/usr/bin/env bash
# Installs agent-handoff-control into ~/.claude/handoff-control and registers its hooks in
# ~/.claude/settings.json. Idempotent; backs up settings.json before changing it.
set -euo pipefail

NOTIFY=0
DSH=0
for a in "$@"; do
  case "$a" in
    --notify) NOTIFY=1 ;;
    --dsh) DSH=1 ;;
    *) echo "install: unknown option '$a' (supported: --notify, --dsh)" >&2; exit 1 ;;
  esac
done

for tool in jq curl python3 perl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "install: '$tool' is required but not found in PATH" >&2; exit 1; }
done

# Validate the DSH hook file before touching the Claude settings: a partial install is worse
# than a clean refusal.
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
DSH_HOOKS="${HANDOFF_DSH_HOOKS:-$DSH_HOME/agent-handoff-control.json}"
if [ "$DSH" = 1 ] && [ -f "$DSH_HOOKS" ]; then
  jq -e 'type == "object"' "$DSH_HOOKS" >/dev/null 2>&1 \
    || { echo "install: $DSH_HOOKS is not a valid JSON object — fix it first, nothing was changed" >&2; exit 1; }
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.claude/handoff-control"
SETTINGS="$HOME/.claude/settings.json"

mkdir -p "$HOME/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 \
  || { echo "install: $SETTINGS is not a valid JSON object — fix it first, nothing was changed" >&2; exit 1; }

mkdir -p "$DEST"
rm -rf "$DEST/hooks" "$DEST/rubrics"
cp -R "$SRC/hooks" "$SRC/rubrics" "$DEST/"
chmod +x "$DEST"/hooks/*.sh "$DEST"/hooks/adapters/*.sh "$DEST"/hooks/lib/ghostty-focus-session

cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"

STOP="bash \"$DEST/hooks/stop-handoff-control.sh\""
CACHE="bash \"$DEST/hooks/prompt-cache.sh\""
LESSON="bash \"$DEST/hooks/lesson-surface.sh\""
NOTIF="bash \"$DEST/hooks/notify-notification.sh\""
DONE="bash \"$DEST/hooks/notify-stop-done.sh\""

TMP=$(mktemp)
jq --arg stop "$STOP" --arg cache "$CACHE" --arg lesson "$LESSON" \
   --arg notif "$NOTIF" --arg done "$DONE" --argjson notify "$NOTIFY" '
  def add($event; $cmd; $timeout):
    if ([.hooks[$event][]?.hooks[]?.command] | index($cmd)) then .
    else .hooks[$event] = ((.hooks[$event] // []) + [{hooks:[{type:"command", command:$cmd, timeout:$timeout}]}])
    end;
  .hooks = (.hooks // {})
  | add("Stop"; $stop; 120)
  | add("UserPromptSubmit"; $cache; 10)
  | add("UserPromptSubmit"; $lesson; 10)
  | if $notify == 1 then add("Notification"; $notif; 10) | add("Stop"; $done; 10) else . end
' "$SETTINGS" > "$TMP" || { rm -f "$TMP"; echo "install: could not update $SETTINGS" >&2; exit 1; }
mv "$TMP" "$SETTINGS"

# DeepSeek Harness reads a Claude-shaped hook config through @deepseek-ai/dsh-hooks-claude-code.
# The adapter rebuilds the Stop payload DSH does not send; foreign hooks in the file are kept.
if [ "$DSH" = 1 ]; then
  DSH_CMD="bash \"$DEST/hooks/adapters/stop-handoff-control-dsh.sh\""
  mkdir -p "$DSH_HOME"
  if [ -f "$DSH_HOOKS" ]; then
    cp "$DSH_HOOKS" "$DSH_HOOKS.bak-$(date +%Y%m%d%H%M%S)"
  else
    echo '{"hooks":{}}' > "$DSH_HOOKS"
  fi
  TMP2=$(mktemp)
  jq --arg c "$DSH_CMD" '
    .hooks = (.hooks // {})
    | .hooks.Stop = ((.hooks.Stop // [])
        | map(.hooks |= map(select(.command != $c)))
        | map(select((.hooks | length) > 0)))
    | .hooks.Stop += [{hooks:[{type:"command", command:$c, timeout:120}]}]
  ' "$DSH_HOOKS" > "$TMP2" \
    || { rm -f "$TMP2"; echo "install: could not update $DSH_HOOKS" >&2; exit 1; }
  mv "$TMP2" "$DSH_HOOKS"
  echo "DSH hook config written to $DSH_HOOKS"
  echo "Mount it in the DSH profile:"
  echo "  - name: '@deepseek-ai/dsh-hooks-claude-code'"
  echo "    config:"
  echo "      configPath: $DSH_HOOKS"
fi

cat <<MSG
agent-handoff-control installed to $DEST
Hooks registered in $SETTINGS (backup saved next to it).

Next: give the judge an API key, e.g. in your shell profile:
  export DEEPSEEK_API_KEY=sk-...             # or HANDOFF_CTL_API_KEY
Optional: HANDOFF_CTL_MODEL (default deepseek-flash), HANDOFF_CTL_API_URL — any Anthropic
Messages–compatible endpoint.
OpenCode Go instead: HANDOFF_CTL_WIRE=openai, HANDOFF_CTL_API_URL=https://opencode.ai/inference/go/v1/chat/completions,
  HANDOFF_CTL_MODEL=deepseek-v4.1-flash, key OPENCODE_API_KEY.
Every forced return raises a macOS notification (Ghostty tab on click); HANDOFF_CTL_NOTIFY=0 mutes it.
Other session statuses (permission, waiting, turn finished): ./install.sh --notify
DeepSeek Harness: ./install.sh --dsh writes the hook config; mount it in the DSH profile.
Restart the agent runtime (Claude Code / DSH) for the hooks to load.
MSG
