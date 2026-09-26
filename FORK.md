> **ARCHIVED 2026-09-26.** Harry now runs official garrytan/gbrain releases
> (bun-link clone of upstream at ~/gbrain, upgraded with `gbrain self-upgrade`).
> The cost guardrails became unnecessary once chat work moved to `claude-cli:`
> (Claude subscription): the remaining per-token spend is OpenAI embeddings,
> capped by an OpenAI project budget limit. Scheduling moved to a hand-made
> 2-hourly LaunchAgent (~/.gbrain/maintenance-run.sh) instead of the upstream
> autopilot daemon. This repository is kept read-only for reference.

# gidonco/gbrain — fork notes

This fork tracks [garrytan/gbrain](https://github.com/garrytan/gbrain) and carries a small set of
**cost guardrails** on top. The local CLI is `bun link`ed to `~/gbrain`, so upgrades go through
`scripts/fork/upgrade.sh`, not `gbrain self-upgrade`. The full procedure is in
[`docs/fork/UPGRADE-RUNBOOK.md`](docs/fork/UPGRADE-RUNBOOK.md).

## Patches carried

| # | Patch | Where | Why upstream isn't enough (as of v0.58.1.0) |
|---|-------|-------|---------------------------------------------|
| 1 | **Daily AI budget governor.** Every priced gateway call (chat, query expansion, embed, rerank, OCR) reserves against a DB-backed ledger capped by `ai.daily_budget_usd`, and fails closed if the cap config is unreadable or a model has no pricing entry. | `src/core/budget/daily-budget.ts`, `src/core/ai/gateway.ts`, `DAILY_AI_BUDGET_CLIENT_ID` in `src/core/minions/budget-meter.ts` | Upstream only has narrow caps: per-OAuth-client MCP spend, per-phase `cycle.*.budget_usd`, a Voyage image-query cap, and a per-job invocation guard for minions. It has no global daily ceiling across processes. |
| 2 | **Zero SDK retries by default.** Chat and embed pass `maxRetries: opts.maxRetries ?? 0`, so callers still opt in explicitly. | `src/core/ai/gateway.ts` | Upstream sets `maxRetries: 0` only inside a minion invocation guard. Everywhere else the AI SDK default applies (2 retries), which can triple the cost of a failing call. |
| 3 | **Autopilot 2-hour floor.** `--min-interval` flag, `resolveAutopilotInterval()` lets the adaptive schedule get slower but never faster, and the generated wrapper execs `--interval 7200 --min-interval 7200`. | `src/commands/autopilot.ts` | Upstream's default is 300 s, and it speeds up when the brain score is low. |
| 4 | **Fail stopped.** The generated launchd plist sets `KeepAlive=false` (systemd uses `Restart=on-failure`), so a crashing daemon stays down instead of respawn-looping into paid calls. | `src/commands/autopilot.ts` | Upstream uses `KeepAlive=true`. |
| 5 | **Single-attempt autonomous jobs.** Most autopilot-submitted AI jobs use `max_attempts: 1`. | `src/commands/autopilot.ts`, `autopilot-fanout.ts` | Upstream uses 2–3 attempts. *Exception kept from upstream:* `extract-atoms-drain` uses 3 attempts (#3218). Its handler now throws on an all-provider-failed batch, and the daily cap still bounds the spend. |

Live configuration on Harry's Mac: `ai.daily_budget_usd = 1.50`. Autopilot runs against `~/brain`
every 7200 s or slower.

### Absorbed upstream (no longer a fork patch)

- **Pessimistic crash accounting in the spend ledger.** Since ~v0.5x, upstream `budget-meter.ts` counts
  expired reservations as outstanding liability for every client, with an advisory lock and a transaction.
  Our v0.42 rewrite of that file was dropped in favour of upstream's; only the `DAILY_AI_BUDGET_CLIENT_ID`
  export remains.
- **Pricing for the default reranker.** ZeroEntropy was sunset and `voyage:rerank-2.5` is priced in
  `src/core/embedding-pricing.ts`. Our ZeroEntropy pricing test was replaced with a Voyage one.

## Are the patches still needed?

Check this on every upgrade (runbook step 0). Drop a patch **only** when upstream ships an equivalent.
When it does, delete the fork code, remove its line from `invariants()` in `scripts/fork/upgrade.sh`,
and move the row to "Absorbed upstream" above.

- Patch 1: search upstream for a *global* daily cap, e.g. `git grep -n "daily_budget_usd" <tag> -- src`
  showing something other than `search.image_query.*`.
- Patch 2: `git grep -n "maxRetries" <tag> -- src/core/ai/gateway.ts` showing a `?? 0` default outside the guard.
- Patches 3–5: `git grep -n "min-interval\|KeepAlive</key>" <tag> -- src/commands/autopilot.ts`.

## Rules

- Never run `gbrain self-upgrade` or `gbrain upgrade`. They fail with "still running X after upgrade",
  and if they succeeded they would drop the guardrails.
- `self_upgrade.mode` stays `notify`: the nag is fine, the auto-swap is not.
- Fork patches live as normal commits on `master`, prefixed `fix(fork):` / `chore(fork):` for new work.
