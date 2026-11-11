#!/usr/bin/env bats
# DSH Stop adapter: DSH sends no last_assistant_message and an empty transcript_path, so the
# adapter rebuilds both from the session journal and calls the core hook with a Claude-shaped
# payload. All tests are offline: the core hook is a stub.

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  ADAPTER="$REPO/hooks/adapters/stop-handoff-control-dsh.sh"
  export HOME="$BATS_TEST_TMPDIR/home"
  export HANDOFF_CTL_HOME="$BATS_TEST_TMPDIR/ctl"
  export HANDOFF_DSH_SESSIONS="$BATS_TEST_TMPDIR/sessions"
  export HANDOFF_DSH_SETTLE=0
  export HANDOFF_DSH_RETRY_DELAY=0
  SID="session-abc"
  mkdir -p "$HANDOFF_CTL_HOME/state" "$HANDOFF_DSH_SESSIONS/--x--/$SID"
  JOURNAL="$HANDOFF_DSH_SESSIONS/--x--/$SID/session.v4.jsonl.zstd"
}

# journal <final> [extra jsonl lines...]
journal() {
  local f="$1"; shift || true
  {
    jq -nc '{type:"agent/inbox/spliced",data:{inserted:[{source:{kind:"user"},content:[{type:"text",text:"add retries"}]}]}}'
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
    jq -nc --arg f "$f" '{type:"assistant/message",data:{message:{content:[{type:"text",text:$f}]}}}'
  } > "$BATS_TEST_TMPDIR/journal.jsonl"
  zstd -q -c "$BATS_TEST_TMPDIR/journal.jsonl" > "$JOURNAL"
}

# stub <answer-json>: records the payload and the key it received, answers with the JSON.
stub() {
  {
    echo '#!/bin/sh'
    echo "cat > \"$BATS_TEST_TMPDIR/payload.json\""
    echo "printf '%s\\n' \"\$DEEPSEEK_API_KEY\" > \"$BATS_TEST_TMPDIR/key.txt\""
    printf 'cat <<%s\n%s\n%s\n' "'JSONEOF'" "$1" "JSONEOF"
  } > "$BATS_TEST_TMPDIR/hook"
  chmod +x "$BATS_TEST_TMPDIR/hook"
  export HANDOFF_CTL_HOOK="$BATS_TEST_TMPDIR/hook"
}

fire() { printf '%s' '{"session_id":"session-abc"}' | bash "$ADAPTER"; }

@test "reconstructs the final and the prompt from the DSH journal" {
  journal 'Retries added.'
  stub '{"decision":"block","reason":"no"}'
  run fire
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "block"'
  jq -e '.last_assistant_message == "Retries added."' "$BATS_TEST_TMPDIR/payload.json"
  jq -e '.transcript_path == "" and .stop_hook_active == false' "$BATS_TEST_TMPDIR/payload.json"
  [ "$(cat "$HANDOFF_CTL_HOME/prompts/session-abc.last-prompt")" = "add retries" ]
}

@test "a subagent journal is not judged as the parent's turn" {
  # The subagent marker sits on the first record; rebuild the head explicitly.
  {
    jq -nc '{parentSession:"s1",origin:"subagent",type:"agent/inbox/spliced",data:{inserted:[{source:{kind:"user"},content:[{type:"text",text:"add retries"}]}]}}'
    jq -nc '{type:"assistant/message",data:{message:{content:[{type:"text",text:"Done."}]}}}'
  } > "$BATS_TEST_TMPDIR/journal.jsonl"
  zstd -q -c "$BATS_TEST_TMPDIR/journal.jsonl" > "$JOURNAL"
  stub '{"decision":"block","reason":"no"}'
  run fire
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$BATS_TEST_TMPDIR/payload.json" ]
}

@test "strips OSC 8 and ANSI from the judge reason" {
  journal 'Done.'
  local raw
  raw=$(jq -nc --arg r $'\033]8;;file://x\033\\VERDICT\033]8;;\033\\ \033[31mred\033[0m' '{decision:"block",reason:$r}')
  stub "$raw"
  run fire
  [ "$status" -eq 0 ]
  local reason
  reason=$(echo "$output" | jq -r .reason)
  [[ "$reason" == *VERDICT* ]]
  [[ "$reason" != *$'\033'* ]]
}

@test "a turn at the return ceiling is not judged again" {
  local splice='{"type":"agent/inbox/spliced","data":{"inserted":[{"source":{"kind":"hooks-claude-code"},"content":[{"type":"text","text":"x"}]}]}}'
  journal 'Done.' "$splice" "$splice" "$splice" "$splice" "$splice" "$splice"
  stub '{"decision":"block","reason":"no"}'
  run fire
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$BATS_TEST_TMPDIR/payload.json" ]
}

@test "a corrupt journal fails open" {
  printf 'garbage' > "$JOURNAL"
  stub '{"decision":"block","reason":"no"}'
  run fire
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$BATS_TEST_TMPDIR/payload.json" ]
}

@test "loads the judge key from the env file" {
  journal 'Done.'
  printf 'DEEPSEEK_API_KEY=secret\n' > "$HANDOFF_CTL_HOME/env"
  chmod 600 "$HANDOFF_CTL_HOME/env"
  stub '{"decision":"block","reason":"no"}'
  run fire
  [ "$(cat "$BATS_TEST_TMPDIR/key.txt")" = secret ]
}

@test "no journal — silent fail-open" {
  rm -f "$JOURNAL"
  stub '{"decision":"block","reason":"no"}'
  run fire
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$BATS_TEST_TMPDIR/payload.json" ]
}
