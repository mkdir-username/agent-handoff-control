#!/usr/bin/env bash
# stop-handoff-control-dsh.sh — Stop adapter for DeepSeek Harness (DSH).
#
# DSH sends a Stop payload without `last_assistant_message` and with an empty `transcript_path`:
# the final message and the user's request are rebuilt from the session journal, then the core
# hook is called with a Claude-shaped payload. A continuation after the core hook's block comes
# back as another Stop; the adapter counts those blocks itself, because DSH always sends
# `stop_hook_active=false`.
#
# Fail-open: no journal, no jq/zstd, a corrupt stream or a dead judge → exit 0 with no output.
# The adapter must never be able to break the end of a turn.

set -uo pipefail

INPUT=$(cat) || exit 0
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
[ -n "$SID" ] || exit 0
case "$SID" in *[!A-Za-z0-9-]*) exit 0 ;; esac

HANDOFF_CTL_HOME="${HANDOFF_CTL_HOME:-$HOME/.claude/handoff-control}"
HOOK="${HANDOFF_CTL_HOOK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/stop-handoff-control.sh}"
SESSIONS="${HANDOFF_DSH_SESSIONS:-${DSH_HOME:-$HOME/.dsh}/sessions}"
ENV_FILE="${HANDOFF_CTL_ENV_FILE:-$HANDOFF_CTL_HOME/env}"
SETTLE="${HANDOFF_DSH_SETTLE:-0.6}"
RETRY_DELAY="${HANDOFF_DSH_RETRY_DELAY:-0.25}"
MAX_BLOCKS="${HANDOFF_DSH_MAX_BLOCKS:-6}"
case "$MAX_BLOCKS" in ''|*[!0-9]*) MAX_BLOCKS=6 ;; esac

# DSH strips variables whose names look sensitive (KEY/TOKEN/SECRET) from child processes,
# so the judge key comes from an env file the user owns. Never from the payload or a log.
if [ -f "$ENV_FILE" ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      DEEPSEEK_API_KEY|OPENCODE_API_KEY|HANDOFF_CTL_*) export "$k=$v" ;;
    esac
  done < "$ENV_FILE"
fi

SESSION_FILE=""
for f in "$SESSIONS"/*/"$SID"/session.v4.jsonl.zstd \
         "$SESSIONS"/*/"session-$SID"/session.v4.jsonl.zstd; do
  [ -f "$f" ] && { SESSION_FILE="$f"; break; }
done
[ -n "$SESSION_FILE" ] || exit 0

TMP=$(mktemp) || exit 0
trap 'rm -f "$TMP"' EXIT

# The journal is appended by a compressed stream: an unfinished tail returns rc 1 and no output.
# Stop fires right after the message is written, so one failed read is normal, not a real error.
snapshot() {
  case "$SESSION_FILE" in
    *.zstd)
      local try=0
      while [ "$try" -lt 4 ]; do
        zstd -dc "$SESSION_FILE" > "$TMP" 2>/dev/null && break
        try=$((try + 1)); sleep "$RETRY_DELAY"
      done
      [ "$try" -lt 4 ] || return 1
      ;;
    *) cp "$SESSION_FILE" "$TMP" 2>/dev/null || return 1 ;;
  esac
  local head
  head=$(head -1 "$TMP" | jq -r '[.parentSession // "", .origin // ""] | @tsv' 2>/dev/null)
  case "$head" in *subagent*) return 2 ;; esac
  return 0
}
snapshot || exit 0

# The request is the last user splice: hook continuations arrive through the same event.
PROMPT=$(jq -rs '
  [ .[] | select(.type=="agent/inbox/spliced") | .data.inserted[]?
    | select((.source.kind // "") == "user")
    | .content[]? | select(.type=="text") | .text ] | last // ""' "$TMP" 2>/dev/null)

last_final() {
  jq -rs '
    [ .[] | select(.type=="assistant/message")
      | {t:(.data.turn // 0),
         x:([.data.message.content[]? | select(.type=="text") | .text] | join(""))}
      | select(.x != "") ] | last // {} | .x // ""' "$TMP" 2>/dev/null
}
FINAL=$(last_final)
[ -n "$FINAL" ] || exit 0

# The tail is still in the compressor for a moment after the message is written: Stop can see
# the previous step instead of the final. A second snapshot after a short pause takes the real
# one; if it does not arrive, the first snapshot stays (fail-open is unchanged).
if [ "$SETTLE" != "0" ]; then sleep "$SETTLE"; fi
if snapshot; then
  NEXT=$(last_final)
  [ -n "$NEXT" ] && FINAL="$NEXT"
fi

# The core hook reads the user's request from this file on UserPromptSubmit; DSH has no such
# event for this cache, so the adapter writes it itself.
PROMPTS_DIR="$HANDOFF_CTL_HOME/prompts"
mkdir -p "$PROMPTS_DIR" 2>/dev/null || true
[ -n "$PROMPT" ] && printf '%s' "$PROMPT" > "$PROMPTS_DIR/$SID.last-prompt" 2>/dev/null || true

# DSH does not fill stop_hook_active, so the core hook's own cascade ceiling never engages:
# count the returns this adapter already made for the current request. The harness writes each
# blocked continuation as a hooks-claude-code splice.
BLOCKS=$(jq -rs '
  . as $all
  | ([ range(0; length)
       | select($all[.] | .type=="agent/inbox/spliced"
                and ([.data.inserted[]? | select((.source.kind // "")=="user")] | length) > 0) ]
     | last) as $i
  | [ $all[($i // 0):][] | select(.type=="agent/inbox/spliced")
      | .data.inserted[]? | select((.source.kind // "")=="hooks-claude-code") ] | length' "$TMP" 2>/dev/null)
case "$BLOCKS" in ''|*[!0-9]*) BLOCKS=0 ;; esac
[ "$BLOCKS" -lt "$MAX_BLOCKS" ] || exit 0

PAYLOAD=$(printf '%s' "$INPUT" | jq -c --arg final "$FINAL" \
  '. + {last_assistant_message:$final, transcript_path:"", stop_hook_active:false}' 2>/dev/null) || exit 0

OUT=$(printf '%s' "$PAYLOAD" | bash "$HOOK" 2>/dev/null) || exit 0
[ -n "$OUT" ] || exit 0

# DSH renders the hook's reason as plain text: OSC 8 links and ANSI colours only hide the
# verdict word between escape bytes. If the answer is not JSON, pass it through unchanged.
CLEAN=$(printf '%s' "$OUT" | jq -c '
  (.reason? // empty) as $r
  | .reason = ($r | gsub("\u001b\\]8;;[^\u001b]*\u001b\\\\"; "")
                   | gsub("\u001b\\[[0-9;]*m"; ""))' 2>/dev/null)
[ -n "$CLEAN" ] || CLEAN="$OUT"

printf '%s' "$CLEAN"
exit 0
