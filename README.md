# agent-handoff-control

Made by and for developers tired of answering the obvious.

A coding agent keeps handing the turn back with questions it could settle itself.
Real last lines from my judge log, translated from Russian:

- *"Fix it? Waiting for your call."*
- *"Do both, or only the test isolation?"*
- *"👉 Next: writing the failing test A2."* — and the turn ends right there.
- *"Say the word and I'll run it."*
- *"Shorten MEMORY.md or leave it as is?"*

Each one pulls you back to the terminal for a one-word "yes".
Step away, and that is an hour of nothing.

This Stop hook for coding agents — [Claude Code](https://code.claude.com) and DeepSeek Harness —
answers for you.
When the next step is obvious, reversible and in reach, the agent gets the turn back
and does it. You get controlled autonomy: the agent keeps going on its own,
and you spend the time on strategy — or on your own things.

## TL;DR

- **What** — at every turn end an LLM judge reads the final message. An excuse gets the turn back.
  It is not a code reviewer and never judges whether the work is right.
- **Where it still stops** — irreversible steps, real forks, anything only a human can do.
- **Cost** — about $0.89 per 1 000 judged turns in 16 days of real use.
- **Safe by default** — one return per chain; any judge failure lets the turn end normally.
  Every forced return rings a macOS notification, so you always know when the judge acted.
- **Two more classes** — `SHELVED` (an improvement named and left) and `FALSE_COMPLETION`
  (a "done" the final itself contradicts) join the original five.
- **Setup** — mine: Claude Opus or DeepSeek Harness as the agent, `deepseek-v4.1-flash` as the
  judge. Adapt it to yours; the default route is DeepSeek's own API.

## Quick start

Requires `bash`, `jq`, `curl`, `python3`, `perl`.

```bash
git clone https://github.com/mkdir-username/agent-handoff-control.git
cd agent-handoff-control && ./install.sh
export DEEPSEEK_API_KEY=sk-...   # or HANDOFF_CTL_API_KEY; put it in your shell profile
```

Restart the agent runtime (Claude Code / DSH) afterwards. `./uninstall.sh` removes everything the
installer added.

DeepSeek Harness: `./install.sh --dsh` writes `~/.dsh/agent-handoff-control.json`; mount it in
your DSH profile (see [DeepSeek Harness](#deepseek-harness-dsh)).

OpenCode Go instead of the DeepSeek API:

```bash
export OPENCODE_API_KEY=sk-...
export HANDOFF_CTL_WIRE=openai
export HANDOFF_CTL_API_URL=https://opencode.ai/inference/go/v1/chat/completions
export HANDOFF_CTL_MODEL=deepseek-v4.1-flash
```

<details>
<summary>What <code>install.sh</code> changes</summary>

- **Files** — copies hooks and rubrics to `~/.claude/handoff-control/`.
- **Settings** — backs up `~/.claude/settings.json`, then registers three hooks:
  Stop, and two on UserPromptSubmit.
- **DSH** — `--dsh` writes `~/.dsh/agent-handoff-control.json` with one Stop hook; your other DSH
  hooks there are kept.
- **Your hooks** — left alone. Running it twice adds nothing new.
- **Uninstall** — removes exactly those three entries and the directory.

</details>

---

## What it catches

The judge answers one question: *was the turn handed back with work, or with an excuse?*

- **DUMB_QUESTION** — a question where one option clearly wins.
  Also a named default not taken, or "do step N+1?" right after step N.
- **MISSED_ACTION** — no question, but an announced or obvious action was not done.
  A failed command left unfixed counts too.
- **DELAYED_ANSWER** — you asked a question and the answer sat behind long foreground waits.
  Never returns the turn; it becomes a lesson for the next one.
- **UNFLAGGED_RISK** — code, a guard or a test deleted, or a contract changed.
  Reported as routine, without evidence and a rollback line.
- **SHELVED** — an improvement or next step inside the user's topic named and left
  ("not now", "if it comes up"), offered as optional, or asked with skipping recommended.
  Never returns the turn: it becomes a lesson inviting a reconsideration.
- **FALSE_COMPLETION** — the final reports the whole request as done while it itself names an
  open part of that request, or while a failed call is neither fixed nor explained.

## What it leaves alone

A verdict of **OK** means the work is done or the stop is legitimate:

- **Irreversible step, direction unclear** — asking first is right.
- **Equal fork** — put to you through AskUserQuestion, or a scope-creep stop.
- **Human-only or banned step** — a policy ban, or a step visible to other people.
- **Flagged risky change** — see the `RESPONSIBLE ZONE` guard below.

💡 The judge sees the final message, your request, tool names and failed-call errors.
It never sees call arguments or successful output. That keeps it cheap and its false positives low.

---

## How a turn is judged

```
Stop ─▶ stop-handoff-control.sh ─▶ LLM judge (rubric) ─▶ verdict + confidence
          │                                                │
          │   ≥ 0.90 evasion ────────────────────────────▶ {"decision":"block","reason":…}
          │                                                  the agent runtime continues the same turn
          │   0.80–0.90, cooldown, background work ───────▶ lesson file
          │                                                  └▶ lesson-surface.sh injects it
          │                                                     into the next turn's context
          └── every verdict ─▶ ~/.claude/handoff-control/verdicts.jsonl
```

- **One return per chain** — `stop_hook_active` prevents loops.
  The continued turn is judged again and may be returned once more, not more.
- **Obligations** — a returned MISSED_ACTION leaves an obligation behind.
  When the agent resumes on its own, the next Stop asks: *is the named action closed?*
- **Deterministic guards** — rules around the LLM that override it (details below).
- **Announced next step** — a final ending on a bare `👉 Next: <own step>` with no question mark
  and no defer marker lowers the block threshold to `0.70`: the agent named work it could do
  now. A question mark keeps `0.90`; `🚧` or "waiting for …" does not lower it.
- **Fail-open** — no key, a timeout or garbage instead of JSON ends the turn normally.
  From the second failure in a row you see a warning naming the error, at most every 30 min.

<details>
<summary>Obligation outcomes and deterministic guards</summary>

Obligation outcomes:

- **met** — the action is done.
- **impossible** — a ban or a human step, proven by the transcript.
- **stalled** — 3 returns without progress.
- **expired** — 1 hour passed. A new message from you supersedes it at any time.

Guards:

- **Background work** — a running background agent or command suppresses MISSED_ACTION.
  Waiting for its notification is legitimate.
- **Responsible zone** — a `⚠️ RESPONSIBLE ZONE` block with `Evidence:` (command → result)
  and `Rollback:` lines makes "Ok / not ok?" a legitimate question.
- **Deletions** — a push that demands deleting something always carries a spike-first protocol.
  It never becomes an obligation.

</details>

---

## Notifications: every forced return is visible

The judge can be wrong. So each time it returns a turn, you hear and see it — even away from the terminal.

- **🛑 HANDOFF** — always on. Plays Sosumi ×3 and shows the verdict and the judge's reason.
  Also fires for an unmet promise and when the judge is unreachable.
- **Click → the right tab** — the banner focuses the Ghostty tab of that session.
  Found by the session's tty, not by its title, so two sessions with one name do not mix.
- **Other statuses** — `./install.sh --notify` adds 🟡 WARN (permission, input needed),
  🔵 INFO (waiting for you) and 🟢 DONE (turn finished). These stay quiet while the tab is in front.
- **Where it works** — macOS. `terminal-notifier` enables click-to-focus; without it a plain
  banner is shown. On other systems it is a silent no-op.
- **Log and off switch** — every banner is a line in `notify.jsonl`; `HANDOFF_CTL_NOTIFY=0` mutes all.

---

## DeepSeek Harness (DSH)

The same controller runs inside DeepSeek Harness through `@deepseek-ai/dsh-hooks-claude-code`.
DSH sends a Stop payload without `last_assistant_message` and with an empty `transcript_path`;
`hooks/adapters/stop-handoff-control-dsh.sh` rebuilds both from the session journal and calls the
core hook with a Claude-shaped payload.

```bash
./install.sh --dsh   # writes ~/.dsh/agent-handoff-control.json
```

Mount it in your DSH profile:

```yaml
- name: '@deepseek-ai/dsh-hooks-claude-code'
  config:
    configPath: /Users/you/.dsh/agent-handoff-control.json
```

- **Key** — DSH strips `KEY`/`TOKEN`/`SECRET` variables from child processes. Put the judge key in
  `~/.claude/handoff-control/env` (`chmod 600`, `KEY=VALUE` per line) or point
  `HANDOFF_CTL_ENV_FILE` at your own file.
- **Returns** — DSH always sends `stop_hook_active=false`, so the adapter counts returns itself:
  at most `HANDOFF_DSH_MAX_BLOCKS` (6) per request.
- **Journal** — `zstd` is required; the adapter reads `~/.dsh/sessions` (override with
  `HANDOFF_DSH_SESSIONS`). A corrupt or not-yet-written journal fails open.
- **Restart** DSH after mounting the hook.

---

## My setup, as it runs

This is my personal setup, published as-is. It is not a product tuned for every stack.

- **Main agent** — Claude Opus in Claude Code, and DeepSeek Harness (DSH).
- **Judge** — `deepseek-v4.1-flash` through OpenCode Go's OpenAI-compatible endpoint
  (`https://opencode.ai/inference/go/v1/chat/completions`). The rubrics were tuned on this pair.
- **Another judge** — any Anthropic Messages- or OpenAI-compatible model plugs in with
  `HANDOFF_CTL_WIRE`, `HANDOFF_CTL_API_URL`, `HANDOFF_CTL_API_KEY` and `HANDOFF_CTL_MODEL`.
  Expect to retune `rubrics/handoff-control.md` yourself; I have not.

## What it costs

16 days of my own work (14–29 Sep 2026): **2 309 judged turns for about $2.06**
(range $0.58–$3.04). That is **$0.89 per 1 000 turns**, about a third of the account's
DeepSeek bill ($6.68).

That measurement is from the Claude Code + `deepseek-flash` pair; the current judge route is
`deepseek-v4.1-flash`, so treat the numbers as a ballpark.

![Daily spend: whole DeepSeek account vs. the controller](docs/spend.svg)

- **Grey** — DeepSeek's billing export. The same key also pays for other tools.
- **Green** — the controller's share, estimated (method below).
- **Where the money goes** — almost all of it is output tokens: thinking plus the verdict.
  The cached rubric is nearly free.

<details>
<summary>How the numbers were measured</summary>

Per call, on the bundled fixture corpus (7 cases × 2):

- **Input** — about 2 700 tokens. After the first call ~2 450 of them (the rubric)
  come from DeepSeek's prompt cache.
- **Output** — 200–1 700 tokens, mostly thinking before the verdict.
- **Latency** — adds 2–10 s to the end of the turn, typically 3–4 s.
- **Calibrator** — evasion verdicts add one tiny call (4 output tokens).

The judge runs once per turn end, plus once for a continuation after a block.
Multiply by your DeepSeek rate for the price.

The green bars: controller calls per day, counted from a local proxy log,
times the per-call profile above, times that day's billed token prices.

</details>

---

## Limitations

- ⚠️ **Current turn only** — work done a turn earlier is invisible to the judge.
  That is why obligations have a ceiling and a TTL.
- ⚠️ **Nondeterministic** — the 17-case corpus passed 17 of 17 on `deepseek-v4.1-flash` in two
  runs, but the judge is still an LLM: reruns can move a class or its confidence.
- ⚠️ **Thinking can eat the budget** — now and then it uses all `HANDOFF_CTL_MAX_TOKENS`
  (8000 by default) and no verdict comes back; that turn passes unchecked and is logged as
  `TRUNCATED`. Raise `HANDOFF_CTL_MAX_TOKENS` if you see it often.
- ⚠️ **Generic policies only** — the rubric knows no push, publish, merge or prod deploy
  without your command. Add your own rules to `rubrics/handoff-control.md`.

A false block costs you one Escape. The rubric leans towards blocking when in doubt;
raise `HANDOFF_CTL_THRESHOLD` if that is too eager for you.

## Configuration

- **`HANDOFF_CTL_WIRE` · `HANDOFF_CTL_API_URL` · `HANDOFF_CTL_API_KEY` · `HANDOFF_CTL_MODEL`** —
  which judge to call. Defaults: `anthropic`, DeepSeek's endpoint, `$DEEPSEEK_API_KEY` (then
  `$OPENCODE_API_KEY`), `deepseek-flash`. For OpenCode Go set `openai` and the
  `https://opencode.ai/inference/go/v1/chat/completions` URL.
- **`HANDOFF_CTL_THRESHOLD`** — confidence needed to return the turn, default `0.90`.
- **Bypass** — `touch ~/.claude/handoff-control/skip` skips the next check.
  Valid 30 min, consumed on use.
- **Tuning** — every verdict lands in `verdicts.jsonl` with the transcript path and line range.
  When the judge is wrong, fix the rubric (`rubrics/handoff-control.md`), not the hook.

<details>
<summary>All variables</summary>

| Variable | Default | Meaning |
|---|---|---|
| `HANDOFF_CTL_API_KEY` | `$DEEPSEEK_API_KEY` | Key for the judge; `$OPENCODE_API_KEY` is the next fallback |
| `OPENCODE_API_KEY` | — | Key fallback for the OpenAI wire |
| `HANDOFF_CTL_API_URL` | `https://api.deepseek.com/anthropic/v1/messages` | Judge endpoint |
| `HANDOFF_CTL_WIRE` | `anthropic` | `anthropic` (Messages API) or `openai` (chat completions) |
| `HANDOFF_CTL_CURL` | `curl` | Curl binary; tests replace it |
| `HANDOFF_CTL_MODEL` | `deepseek-flash` | Judge model |
| `HANDOFF_CTL_TIMEOUT` | `60` | Judge request timeout, seconds |
| `HANDOFF_CTL_BUDGET` | `90` | Total time the hook may spend, seconds |
| `HANDOFF_CTL_MAX_TOKENS` | `8000` | Judge output cap; raise it if thinking eats the budget |
| `HANDOFF_CTL_ANNOUNCE_THRESHOLD` | `0.70` | Confidence needed to return an announced next step |
| `HANDOFF_CTL_THRESHOLD` | `0.90` | Confidence needed to return the turn |
| `HANDOFF_CTL_SOFT_THRESHOLD` | `0.80` | Confidence needed for a next-turn lesson |
| `HANDOFF_CTL_DELAYED_THRESHOLD` | `0.70` | Confidence needed for a DELAYED_ANSWER lesson |
| `HANDOFF_CTL_COOLDOWN` | `600` | Seconds MISSED_ACTION stays a lesson after an "impossible" |
| `HANDOFF_CTL_OBLIGATION_TTL` | `3600` | Obligation lifetime, seconds |
| `HANDOFF_CTL_OBLIGATION_MAX_ITER` | `3` | Returns before an obligation is closed as stalled |
| `HANDOFF_CTL_BG_WINDOW` | `3600` | How long a background launch counts as "in flight" |
| `HANDOFF_CTL_DELIVER_MAX` | `900` | Max age of a lesson that is still delivered |
| `HANDOFF_CTL_COMMIT_IN_DIALOG` | `0` | `1` if your policy is that the agent hands you commits as a command |
| `HANDOFF_CTL_ENV_FILE` | `$HANDOFF_CTL_HOME/env` | Key file the DSH adapter reads |
| `HANDOFF_DSH_SESSIONS` | `$DSH_HOME/sessions` | DSH session journal directory |
| `HANDOFF_DSH_MAX_BLOCKS` | `6` | Returns the DSH adapter may make per request |
| `HANDOFF_DSH_SETTLE` | `0.6` | Pause before the second journal snapshot, seconds |
| `HANDOFF_DSH_RETRY_DELAY` | `0.25` | Delay between journal read retries, seconds |
| `HANDOFF_DSH_HOOKS` | `$DSH_HOME/agent-handoff-control.json` | DSH hook config written by install/uninstall |
| `HANDOFF_CTL_HOOK` | the sibling core hook | Core hook the DSH adapter calls |
| `HANDOFF_CTL_HOME` | `~/.claude/handoff-control` | State, prompt cache and verdict log |
| `HANDOFF_CTL_LOG` | `$HANDOFF_CTL_HOME/verdicts.jsonl` | Verdict log |
| `HANDOFF_CTL_RUBRIC_DIR` | `<install>/rubrics` | Directory with the three rubrics |
| `HANDOFF_CTL_RUBRIC` · `HANDOFF_CTL_OBLIGATION_RUBRIC` · `HANDOFF_CTL_CALIB_PROMPT` | files in the rubric dir | Override one rubric |
| `HANDOFF_CTL_CALIB` | `1` | Logprob calibrator on evasion verdicts (logged only, never changes a verdict); `0` turns it off |
| `HANDOFF_CTL_CALIB_URL` | `https://api.deepseek.com/v1/chat/completions` | OpenAI-compatible endpoint returning `top_logprobs` |
| `HANDOFF_CTL_CALIB_KEY` · `HANDOFF_CTL_CALIB_MODEL` · `HANDOFF_CTL_CALIB_TIMEOUT` | judge key · judge model · `10` | Calibrator overrides |
| `HANDOFF_CTL_CMD` · `HANDOFF_CTL_CALIB_CMD` | — | Replace the judge/calibrator with a command (tests, custom transports) |
| `HANDOFF_CTL_DOWN_FILE` | `$HANDOFF_CTL_HOME/state/ctl-down` | Consecutive-failure counter |
| `HANDOFF_CTL_NOTIFY` | `1` | `0` mutes every notification |
| `HANDOFF_CTL_NOTIFY_SOUND` | `Sosumi` | System sound for HANDOFF, played 3 times |
| `HANDOFF_CTL_NOTIFY_LOG` | `$HANDOFF_CTL_HOME/notify.jsonl` | Log of sent notifications and clicks |
| `HANDOFF_CTL_NOTIFY_CMD` · `HANDOFF_CTL_NOTIFY_TTY` | — | Replace sending with a command; force the session tty (tests) |

</details>

## What leaves your machine

On every Stop the judge endpoint receives the rubric plus:

- **Final message** — its last ~3 000 characters.
- **Your prompt** — its first 1 500 characters.
- **Tool names** — the list of tools called in the turn.
- **Errors** — for failed calls, the first 120 characters of the error text.
  They pass through a secret mask first: API keys, GitHub/Slack/AWS tokens, JWTs, `key=value`.

Tool arguments and successful tool output are never sent. The request goes to
`HANDOFF_CTL_API_URL` (DeepSeek's API by default). The DSH adapter reads only the local session
journal and sends the same fields. Nothing else leaves the machine.

---

## Related, not included: `/goal`

A task-goal system pairs well with this hook. It is a **separate setup, installed manually**,
and not part of this package: a session goal in the status line, plus a PreToolUse gate
that blocks work until a goal is set.

The two do not talk to each other. They cover the two ends of a task:
a stated goal before work starts, and work instead of excuses at every turn end.

## Tests

```bash
bats tests/                    # every hook; the judge is stubbed, no API calls
bats tests/dsh-adapter.bats    # the DSH adapter on synthetic journals
HANDOFF_CTL_LIVE=1 HANDOFF_CTL_LIVE_KEY="$OPENCODE_API_KEY" \
  HANDOFF_CTL_LIVE_WIRE=openai \
  HANDOFF_CTL_LIVE_URL=https://opencode.ai/inference/go/v1/chat/completions \
  HANDOFF_CTL_LIVE_MODEL=deepseek-v4.1-flash \
  bats tests/stop-handoff-control.bats -f 'live judge'
```

## License

MIT
