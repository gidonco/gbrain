# GBrain fork upgrade runbook

Repeatable procedure to move Harry's GBrain (`~/gbrain`, fork `gidonco/gbrain`) onto a new
upstream release of `garrytan/gbrain` while keeping the fork patches listed in [`FORK.md`](../../FORK.md).

**One command per phase.** Each phase stops on the first problem and prints the next step.

```
scripts/fork/upgrade.sh status        # 0. what's installed / available / are the patches intact
scripts/fork/upgrade.sh prepare       # 1. backup + worktree + merge latest upstream tag
                                      #    (exit 2 = conflicts → resolve with the playbook below)
scripts/fork/upgrade.sh verify --affected  # 2. install, flag registry, typecheck, guardrail tests, invariants,
                                           #    + isolated affected-area sweep diffed against pristine upstream
scripts/fork/upgrade.sh cutover       # 3. ff live checkout, migrations, autopilot reinstall, live checks
#   → restart Claude Desktop / Claude Code so their `gbrain serve` MCP processes load the new code
scripts/fork/upgrade.sh push          # 4. sync gidonco/gbrain on GitHub
scripts/fork/upgrade.sh cleanup       # 5. remove worktree + upgrade branch
scripts/fork/upgrade.sh check         #    re-run live checks any time
scripts/fork/upgrade.sh rollback      #    emergency: back to newest backup/pre-upgrade-* tag
```

Nothing is deleted except the merged upgrade worktree and branch. Every run creates a
`backup/pre-upgrade-<ts>` git tag and a `~/.gbrain/backups/upgrade-<ts>/` snapshot (config.json,
autopilot wrapper, LaunchAgent plists). Logs go to `~/.gbrain/upgrade-logs/`.

## 0. Before you start

1. `status` must show all invariants **OK** on the current install. If one fails, fix it first.
2. Read the upstream CHANGELOG entries between the installed version and the target
   (`git -C ~/gbrain log --oneline master..<tag> -- CHANGELOG.md`, then read the file at `<tag>`).
   Look for:
   - anything touching **AI gateway / budget / retries / autopilot scheduling / launchd**, which may conflict with or supersede a fork patch
   - **schema migrations** marked long-running or destructive
   - changes to **default models or providers**. The daily cap fails closed on unpriced models, so a new default model without a pricing entry will be refused.
3. Re-evaluate whether each patch is still needed ("Are the patches still needed?" in `FORK.md`).

## 1. Conflict playbook

The fork touches few files, so conflicts cluster there. General rule: **take upstream's structure and
re-apply the fork's intent.** Never keep a half-merged file. If upstream rewrote a file, take theirs
wholesale (`git checkout --theirs <file>`) and re-add the fork lines.

| File | Resolution |
|------|------------|
| `CHANGELOG.md` | `git checkout --theirs CHANGELOG.md`, then re-add the "Fork patches (gidonco/gbrain)" section under the header. |
| `src/core/cli-flag-registry.generated.ts` | `git checkout --theirs`. `verify` regenerates it (`bun run build:flag-registry`) and commits it. |
| `src/commands/autopilot.ts` (wrapper template) | Take upstream's wrapper body. Every `exec … autopilot --repo '${safeRepoPath}'` line must end in `--interval 7200 --min-interval 7200`, including fallback exec lines. Keep `'--min-interval'` in `AUTOPILOT_VALUE_FLAGS`, `resolveAutopilotInterval`, `KeepAlive</key><false/>` and `Restart=on-failure`. |
| `src/core/ai/gateway.ts` | Take upstream's call structure (e.g. `guardedGeneration`, `invokeAI`, `isAIInvocationPolicyError`). Keep every `reserveDailyBudget` / `settleDailyBudget` pair: settle in `finally`, or in the catch **before** any rethrow. Inject `maxRetries: opts.maxRetries ?? 0` into the chat transport options. Embed uses `maxRetries: hasAIInvocationGuard() ? 0 : (opts?.maxRetries ?? 0)`. |
| `src/core/minions/budget-meter.ts` | Upstream owns this file now. Take theirs and re-add `export const DAILY_AI_BUDGET_CLIENT_ID = 'gbrain:daily-ai';` after `RESERVATION_TTL_MS`. |
| `src/core/budget/*`, `test/**` | If a fork test encodes old upstream behaviour (e.g. pricing for a sunset provider, old ledger semantics), update it to assert the **intent** against the new behaviour, or take upstream's test. Don't weaken guardrail assertions. |

After resolving: `git -C ~/gbrain-upgrade add -A && git -C ~/gbrain-upgrade commit --no-edit`.

## 2. Verify: the quality gate

`verify` fails the upgrade unless all of these pass:

1. No conflict markers left; `bun install` succeeds.
2. The flag registry regenerates without drift.
3. `bun run typecheck` is clean.
4. The guardrail test set is green: daily-budget gateway tests, budget-meter, budget-tracker, autopilot, flag validation, OCR budget, config-set.
5. Every **fork patch invariant** holds (grep-level proof that each patch survived the merge).

6. With `--affected` (recommended; ~15–30 min): every test file touching gateway / autopilot / budget /
   expansion / OCR / rerank / embed is run **in its own process**. A failing file is re-run against a pristine
   checkout of the upstream tag (`~/gbrain-baseline`), and only *fork-caused* regressions fail the gate
   (baseline green, fork red). Files that are red upstream too are listed as `upstream-red` for information.
   Don't run many test files in one `bun test a b c …` process: they share module state and PGLite
   directories, and the result is dozens of false failures.

`verify --full` runs the whole unit suite (~1,900 files; hours on a Mac). Upstream CI already runs it
for every release, so it is optional.

## 3. Cutover

1. **Quiesce.** Boot out autopilot and stop every `gbrain serve`, `jobs work` and `jobs supervisor` process.
   Hermes, Claude Desktop and Claude Code spawn `gbrain serve` as their MCP server. Then cancel any job still
   marked `active`: with no workers left, such jobs are orphaned. Some schema migrations refuse to run otherwise,
   for example v149 `minion_submission_authority`.
2. **Fast-forward** the live `~/gbrain` master. There are never merge commits on the live checkout.
   `bun install` runs gbrain's postinstall, which already attempts migrations.
3. **Migrate.** Run `gbrain post-upgrade --no-autopilot-install`, then `gbrain apply-migrations --yes`.
   - A **schema** migration failure is fatal: the script stops and autopilot stays down.
   - A **feature (orchestrator)** migration finishing `PARTIAL` or `WEDGED` is reported but does not block.
     These need an opt-in host decision. Example: v0.53.0 shared-skills adoption.
4. **Reinstall autopilot** with `gbrain autopilot --install --repo ~/brain`, then load it.
5. **Live checks.** The version matches `package.json`, `ai.daily_budget_usd = 1.50`, `KeepAlive=false`,
   the wrapper has the 2 h floor, the plist holds no secrets, `doctor` ran, and all invariants hold.
6. **Restart the MCP host apps** (Hermes, Claude Desktop, Claude Code) so they respawn `gbrain serve` on the new code.

## 4–5. Push and clean up

`push` sends `master` and the `backup/*` tags to `origin` (gidonco/gbrain). `cleanup` refuses to delete the
worktree unless its branch is merged into master.

## Rollback

`rollback [backup/pre-upgrade-<ts>]` tags the current HEAD as `rollback/from-<ts>`, hard-resets the live
master to the backup tag, reinstalls deps and the autopilot. Schema migrations are forward-only. An older CLI
normally runs against a newer schema, but check `gbrain doctor`. Restore `~/.gbrain/config.json` from
the matching `~/.gbrain/backups/upgrade-<ts>/` only if it was changed.

## Upgrade log

| Date | From → To | Conflicts | Notes |
|------|-----------|-----------|-------|
| 2026-07-18 | 0.42.62.0 | – | Cost guardrails introduced (PR #1). |
| 2026-09 | 0.42.62.0 → 0.48.2.0 | autopilot `--min-interval` | Merged locally, not pushed until 2026-09-26. |
| 2026-09-26 | 0.48.2.0 → 0.58.1.0 | CHANGELOG, autopilot.ts, gateway.ts (4), budget-meter.ts (7), flag registry | budget-meter.ts taken from upstream (pessimistic expiry is now native). ZeroEntropy pricing test replaced with Voyage. Wrapper test pinned to the 2 h floor. Schema 145 → 165. v149 was blocked by an orphaned `active` sync job from 2026-09-05 (cancelled), which led to the quiesce step. v0.53.0 shared-skills adoption left PARTIAL (opt-in). Autopilot had been down since 2026-09-05 and was restarted. Workflow script and runbook added. |
