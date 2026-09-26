#!/usr/bin/env bash
# gidonco/gbrain fork upgrade workflow.
#
# Pulls a new upstream (garrytan/gbrain) release into the fork, keeps the fork
# patches (see FORK.md), verifies them, cuts the live install over, and syncs
# the fork on GitHub. Every phase is idempotent and stops loudly on failure.
#
#   scripts/fork/upgrade.sh status             what's installed, what's available
#   scripts/fork/upgrade.sh prepare [TAG]      backup + worktree + merge (default: latest upstream tag)
#   scripts/fork/upgrade.sh verify [--affected|--full]
#                                              install, typecheck, guardrail tests, patch invariants
#                                              --affected: + every gateway/autopilot/budget/embed test file,
#                                              isolated, diffed against pristine upstream (recommended)
#   scripts/fork/upgrade.sh cutover            ff live checkout, migrations, autopilot reinstall, live checks
#   scripts/fork/upgrade.sh push               push master + backup tags to origin (gidonco/gbrain)
#   scripts/fork/upgrade.sh cleanup            remove the upgrade worktree/branch
#   scripts/fork/upgrade.sh rollback [TAG]     reset live checkout to a backup tag (default: newest)
#
# NEVER run `gbrain self-upgrade` / `gbrain upgrade` on this machine: gbrain is
# `bun link`ed to ~/gbrain, so upstream's installer cannot swap it and would, if
# it could, silently drop the fork's cost guardrails.
set -euo pipefail

LIVE="${GBRAIN_LIVE_CHECKOUT:-$HOME/gbrain}"
WT="${GBRAIN_UPGRADE_WORKTREE:-$HOME/gbrain-upgrade}"
BRAIN_REPO="${GBRAIN_BRAIN_REPO:-$HOME/brain}"
GBRAIN_HOME="${GBRAIN_HOME:-$HOME/.gbrain}"
PLIST="$HOME/Library/LaunchAgents/com.gbrain.autopilot.plist"
EXPECTED_DAILY_BUDGET="${GBRAIN_EXPECTED_DAILY_BUDGET:-1.50}"
LOGDIR="$GBRAIN_HOME/upgrade-logs"
export PATH="$HOME/.bun/bin:$PATH"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_off=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s!!%s  %s\n' "$c_ylw" "$c_off" "$*" >&2; }
die()  { printf '%sXX%s  %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
ok()   { printf '   %sOK%s   %s\n' "$c_grn" "$c_off" "$*"; }
bad()  { printf '   %sFAIL%s %s\n' "$c_red" "$c_off" "$*"; FAILS=$((FAILS+1)); }
FAILS=0

# gbrain prints an upgrade nag on stdout; strip it from values we parse.
gb() { gbrain "$@" 2>/dev/null | grep -v -e '^UPGRADE_AVAILABLE' -e 'available. Run: gbrain self-upgrade' -e '^\[gbrain\]'; }

latest_tag() { git -C "$LIVE" tag -l 'v[0-9]*' --sort=-v:refname | head -1; }
installed_version() { gbrain --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+){3}' | head -1; }

preflight() {
  command -v bun >/dev/null || die "bun not on PATH"
  command -v gbrain >/dev/null || die "gbrain not on PATH"
  local target; target=$(readlink -f "$(command -v gbrain)")
  [[ "$target" == "$LIVE/src/cli.ts" ]] || die "gbrain resolves to $target, expected $LIVE/src/cli.ts (bun link broken?)"
  git -C "$LIVE" remote get-url upstream >/dev/null 2>&1 || git -C "$LIVE" remote add upstream https://github.com/garrytan/gbrain.git
  [[ "$(git -C "$LIVE" rev-parse --abbrev-ref HEAD)" == master ]] || die "$LIVE is not on master"
  [[ -z "$(git -C "$LIVE" status --porcelain)" ]] || die "$LIVE has uncommitted changes; commit or stash first"
}

# ---- patch invariants: the fork patches must survive every merge ----------
invariants() {
  local dir="$1"; local f
  say "Fork patch invariants in $dir"
  f="$dir/src/core/budget/daily-budget.ts"
  [[ -f "$f" ]] && ok "daily AI budget governor present" || bad "src/core/budget/daily-budget.ts missing"
  f="$dir/src/core/ai/gateway.ts"
  local n; n=$(grep -c 'reserveDailyBudget(' "$f" || true)
  (( n >= 5 )) && ok "gateway reserves daily budget at $n call sites (chat/expand/embed/rerank/ocr)" || bad "gateway reserveDailyBudget call sites: $n (<5)"
  grep -q 'maxRetries: opts.maxRetries ?? 0' "$f" && ok "chat: zero SDK retries by default" || bad "chat maxRetries default lost"
  grep -q 'maxRetries: hasAIInvocationGuard() ? 0 : (opts?.maxRetries ?? 0)' "$f" && ok "embed: zero SDK retries by default" || bad "embed maxRetries default lost"
  f="$dir/src/core/minions/budget-meter.ts"
  grep -q "DAILY_AI_BUDGET_CLIENT_ID" "$f" && ok "budget-meter exports DAILY_AI_BUDGET_CLIENT_ID" || bad "DAILY_AI_BUDGET_CLIENT_ID missing"
  f="$dir/src/commands/autopilot.ts"
  grep -q "'--min-interval'" "$f" && ok "autopilot accepts --min-interval" || bad "--min-interval flag lost"
  n=$(grep -c -- "--interval 7200 --min-interval 7200" "$f" || true)
  (( n >= 1 )) && ok "installed wrapper pins 2h floor ($n exec lines)" || bad "wrapper no longer pins --interval 7200 --min-interval 7200"
  grep -q '<key>KeepAlive</key><false/>' "$f" && ok "launchd KeepAlive=false (fail stopped)" || bad "launchd KeepAlive is no longer false"
  grep -q "resolveAutopilotInterval" "$f" && ok "adaptive interval respects floor" || bad "resolveAutopilotInterval missing"
  grep -q -- "'--min-interval'" "$dir/src/core/cli-flag-registry.generated.ts" && ok "flag registry knows --min-interval" || bad "flag registry missing --min-interval (run: bun run build:flag-registry)"
}

cmd_status() {
  git -C "$LIVE" fetch -q upstream --tags
  git -C "$LIVE" fetch -q origin
  local tag; tag=$(latest_tag)
  say "Installed: $(installed_version)  (linked to $LIVE)"
  say "Latest upstream tag: $tag"
  say "Live master vs origin (gidonco): $(git -C "$LIVE" rev-list --left-right --count origin/master...master | awk '{print "behind "$1", ahead "$2}')"
  say "Upstream commits not yet merged: $(git -C "$LIVE" rev-list --count master.."$tag")"
  say "Fork-only commits (no merges):"
  git -C "$LIVE" log --oneline --no-merges upstream/master..master | sed 's/^/     /'
  invariants "$LIVE"
  [[ -f "$GBRAIN_HOME/upgrade-errors.jsonl" ]] && { say "Last upgrade error:"; tail -1 "$GBRAIN_HOME/upgrade-errors.jsonl" | sed 's/^/     /'; }
  return 0
}

cmd_prepare() {
  preflight
  git -C "$LIVE" fetch -q upstream --tags
  local tag="${1:-$(latest_tag)}"
  git -C "$LIVE" rev-parse -q --verify "$tag^{commit}" >/dev/null || die "unknown tag $tag"
  if git -C "$LIVE" merge-base --is-ancestor "$tag" master; then say "master already contains $tag"; return 0; fi
  local ts; ts=$(date +%Y%m%d-%H%M)
  say "Backup: tag backup/pre-upgrade-$ts + ~/.gbrain snapshot"
  git -C "$LIVE" tag -a "backup/pre-upgrade-$ts" -m "before merging $tag" master
  local bdir="$GBRAIN_HOME/backups/upgrade-$ts"; mkdir -p "$bdir"
  cp -p "$GBRAIN_HOME/config.json" "$bdir/"
  cp -p "$GBRAIN_HOME/autopilot-run.sh" "$bdir/" 2>/dev/null || true
  cp -p "$HOME"/Library/LaunchAgents/com.gbrain.*.plist "$bdir/" 2>/dev/null || true
  chmod 700 "$bdir"
  if [[ -d "$WT" ]]; then die "worktree $WT already exists (finish or run: $0 cleanup)"; fi
  say "Worktree $WT on branch upgrade/$tag"
  git -C "$LIVE" worktree add -q "$WT" -b "upgrade/$tag" master
  say "Merging $tag"
  if git -C "$WT" merge --no-edit -m "Merge upstream $tag into fork" "$tag"; then
    say "Merged cleanly. Next: $0 verify"
  else
    warn "Conflicts in:"
    git -C "$WT" diff --name-only --diff-filter=U | sed 's/^/     /'
    warn "Resolve them in $WT following docs/fork/UPGRADE-RUNBOOK.md (conflict playbook),"
    warn "then: git -C $WT add -A && git -C $WT commit --no-edit && $0 verify"
    exit 2
  fi
}

cmd_verify() {
  [[ -d "$WT" ]] || die "no worktree at $WT (run prepare first)"
  [[ -z "$(git -C "$WT" diff --name-only --diff-filter=U)" ]] || die "unresolved conflicts remain"
  if grep -rIlE '^(<<<<<<<|>>>>>>>) ' "$WT/src" "$WT/test" 2>/dev/null; then die "conflict markers left in the files above"; fi
  mkdir -p "$LOGDIR"
  cd "$WT"
  say "bun install";            bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null
  say "regenerate flag registry"; bun run build:flag-registry >/dev/null
  if [[ -n "$(git status --porcelain src/core/cli-flag-registry.generated.ts)" ]]; then
    git add src/core/cli-flag-registry.generated.ts
    git commit -q -m "chore(fork): regenerate CLI flag registry" && say "committed regenerated flag registry"
  fi
  say "typecheck";              bun run typecheck >"$LOGDIR/typecheck.log" 2>&1 || die "typecheck failed (see $LOGDIR/typecheck.log)"
  say "guardrail test set"
  bun test test/ai/gateway-daily-budget.serial.test.ts test/ai/gateway-chat.test.ts \
    test/minions/budget-meter.test.ts test/budget-meter.test.ts test/budget-tracker.test.ts \
    test/core/budget test/autopilot-reconnect-classifier.test.ts test/autopilot-self-upgrade.test.ts \
    test/cli-flag-validation.test.ts test/ocr-run-budget.test.ts test/config-set.test.ts \
    test/autopilot-install-wrapper.serial.test.ts \
    >"$LOGDIR/guardrail-tests.log" 2>&1 || { grep -E '^\(fail\)' "$LOGDIR/guardrail-tests.log" | sort -u; die "guardrail tests failed (see $LOGDIR/guardrail-tests.log)"; }
  ok "$(grep -E '^ *[0-9]+ pass' "$LOGDIR/guardrail-tests.log" | tr -s ' ')"
  FAILS=0; invariants "$WT"; (( FAILS == 0 )) || die "$FAILS fork patch invariant(s) failed"
  if [[ "${1:-}" == "--affected" ]]; then affected_sweep; fi
  if [[ "${1:-}" == "--full" ]]; then
    say "full unit suite (slow; log: $LOGDIR/unit.log)"
    bun run test >"$LOGDIR/unit.log" 2>&1 || { tail -40 "$LOGDIR/unit.log"; die "unit suite failed"; }
    ok "unit suite green"
  fi
  say "Verified. Next: $0 cutover"
}

# Every test file touching the fork's areas, each in its OWN bun process (files
# share module state and PGLite dirs, so a single `bun test a b c` run produces
# false failures). A failing file is re-run against a pristine upstream checkout
# of the merged tag; only fork-caused regressions (baseline green, fork red) fail.
affected_sweep() {
  local tag; tag=$(git -C "$WT" rev-parse --abbrev-ref HEAD); tag=${tag#upgrade/}
  git -C "$WT" rev-parse -q --verify "$tag^{commit}" >/dev/null || die "cannot derive upstream tag from branch name ($tag)"
  local base="$HOME/gbrain-baseline"
  local list="$LOGDIR/affected-files.txt" res="$LOGDIR/affected-results.txt"
  (cd "$WT" && find test -type f -name '*.test.ts' ! -name '*.e2e.*' ! -path 'test/e2e/*' \
     | grep -E 'gateway|autopilot|budget|expansion|ocr|rerank|embed' | sort) >"$list"
  say "affected sweep: $(wc -l <"$list" | tr -d ' ') files, one process each (log: $res)"
  : >"$res"; local regress=0 f
  while read -r f; do
    if (cd "$WT" && timeout 900 bun test "$f" >/dev/null 2>&1); then echo "ok   $f" >>"$res"; continue; fi
    if [[ ! -d "$base" ]]; then git -C "$LIVE" worktree add -q --detach "$base" "$tag"; (cd "$base" && bun install >/dev/null 2>&1); fi
    git -C "$base" checkout -q --detach "$tag"
    if (cd "$base" && timeout 900 bun test "$f" >/dev/null 2>&1); then
      echo "REGRESSION $f" >>"$res"; regress=$((regress+1))
    else
      echo "upstream-red $f" >>"$res"
    fi
  done <"$list"
  grep -v '^ok ' "$res" | sed 's/^/     /' || true
  (( regress == 0 )) && ok "no fork-caused regressions" || die "$regress fork-caused regression(s) — see $res"
}

# Stop everything that writes to the brain before migrating. Some migrations
# (e.g. v149 minion_submission_authority) refuse to run while any job is 'active'
# or older-code writers are connected.
quiesce() {
  say "Quiesce: stop autopilot, old 'gbrain serve' MCP servers, orphaned jobs"
  launchctl bootout "gui/$(id -u)/com.gbrain.autopilot" 2>/dev/null || true
  sleep 2
  local p pp
  for p in $(pgrep -f 'gbrain (serve|autopilot|jobs work|jobs supervisor)' || true); do
    pp=$(ps -o ppid= -p "$p" | tr -d ' ')
    warn "stopping pid $p ($(ps -o command= -p "$p" | cut -c1-60)) — parent: $(ps -o comm= -p "$pp" 2>/dev/null)"
    kill "$p" 2>/dev/null || true
  done
  sleep 3
  pgrep -f 'gbrain serve' >/dev/null && die "gbrain serve still running; stop its host app (Hermes / Claude Desktop / Claude Code) and retry"
  # With every worker stopped, any job still marked 'active' is orphaned.
  local ids
  ids=$(gb jobs list --status active --json | python3 -c 'import json,sys
try: print(" ".join(str(j["id"]) for j in json.load(sys.stdin)))
except Exception: pass')
  for p in $ids; do warn "cancelling orphaned active job #$p"; gb jobs cancel "$p" >/dev/null || true; done
  ok "quiesced"
}

cmd_cutover() {
  preflight
  [[ -d "$WT" ]] || die "no worktree at $WT"
  local branch; branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD)
  git -C "$LIVE" merge-base --is-ancestor master "$branch" || die "$branch does not descend from master"
  mkdir -p "$LOGDIR"
  quiesce
  say "Fast-forward $LIVE master -> $branch"
  git -C "$LIVE" merge --ff-only -q "$branch"
  # bun install runs gbrain's postinstall, which already attempts schema migrations.
  (cd "$LIVE" && bun install >"$LOGDIR/bun-install.log" 2>&1) || die "bun install failed (see $LOGDIR/bun-install.log)"
  local v; v=$(installed_version); local want; want=$(grep -Eo '"version": *"[^"]+"' "$LIVE/package.json" | grep -Eo '[0-9.]+[0-9]')
  [[ "$v" == "$want" ]] && ok "gbrain --version = $v" || die "gbrain reports $v, package.json says $want"
  say "post-upgrade (migrations; log: $LOGDIR/post-upgrade.log)"
  gbrain post-upgrade --no-autopilot-install >"$LOGDIR/post-upgrade.log" 2>&1 || true
  gbrain apply-migrations --yes >"$LOGDIR/apply-migrations.log" 2>&1 || true
  # Schema migrations are mandatory: autopilot must never run new code on a half-migrated schema.
  if grep -q 'Schema migration failed' "$LOGDIR/apply-migrations.log"; then
    grep 'Schema migration failed' "$LOGDIR/apply-migrations.log" | tail -1 >&2
    die "schema migration failed — autopilot left STOPPED. Fix the cause, run 'gbrain apply-migrations --yes', then '$0 check' and 'launchctl bootstrap gui/$(id -u) $PLIST'"
  fi
  ok "schema migrations applied"
  # Orchestrator (feature) migrations may finish PARTIAL when they need an opt-in host decision; not a blocker.
  grep -hE 'finished as PARTIAL|WEDGED' "$LOGDIR/post-upgrade.log" "$LOGDIR/apply-migrations.log" 2>/dev/null | sort -u | sed 's/^/     note: /' || true
  say "Reinstall autopilot from the fork build"
  gbrain autopilot --install --repo "$BRAIN_REPO" >"$LOGDIR/autopilot-install.log" 2>&1 || die "autopilot --install failed (see log)"
  launchctl list | grep -q com.gbrain.autopilot || launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  cmd_live_checks
}

cmd_live_checks() {
  FAILS=0
  say "Live checks"
  local b; b=$(gb config get ai.daily_budget_usd | tail -1 | tr -d '[:space:]')
  [[ "$b" == "$EXPECTED_DAILY_BUDGET" ]] && ok "ai.daily_budget_usd = $b" || bad "ai.daily_budget_usd = '${b}' (expected $EXPECTED_DAILY_BUDGET) — fix: gbrain config set ai.daily_budget_usd $EXPECTED_DAILY_BUDGET"
  if [[ -f "$PLIST" ]]; then
    plutil -extract KeepAlive raw "$PLIST" 2>/dev/null | grep -q false && ok "plist KeepAlive=false" || bad "plist KeepAlive is not false"
    grep -q -- "--interval 7200 --min-interval 7200" "$GBRAIN_HOME/autopilot-run.sh" && ok "wrapper runs every >=2h" || bad "wrapper lacks 2h floor"
    grep -qiE 'sk-|API_KEY' "$PLIST" && bad "plist contains an API key" || ok "no secrets in plist"
  else bad "no autopilot plist"; fi
  launchctl list | grep -q com.gbrain.autopilot && ok "autopilot loaded" || warn "autopilot not loaded (load: launchctl bootstrap gui/$(id -u) $PLIST)"
  gb doctor --json >"$LOGDIR/doctor.json" 2>/dev/null && ok "doctor ran (report: $LOGDIR/doctor.json)" || warn "doctor returned non-zero — review $LOGDIR/doctor.json"
  FAILS_LIVE=$FAILS; invariants "$LIVE"; FAILS=$((FAILS+FAILS_LIVE))
  if ! pgrep -f 'gbrain serve' >/dev/null; then
    warn "no 'gbrain serve' running — restart the MCP host apps (Hermes, Claude Desktop, Claude Code) so they respawn it on the new code"
  fi
  (( FAILS == 0 )) && say "Cutover verified. Next: $0 push && $0 cleanup" || die "$FAILS live check(s) failed"
}

cmd_push() {
  git -C "$LIVE" push origin master
  git -C "$LIVE" push origin 'refs/tags/backup/*' 2>/dev/null || true
  say "gidonco/gbrain master = $(git -C "$LIVE" rev-parse --short master)"
}

cmd_cleanup() {
  [[ -d "$WT" ]] || { say "no worktree"; return 0; }
  local branch; branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD)
  git -C "$LIVE" merge-base --is-ancestor "$branch" master || die "$branch is not merged into master; refusing to remove"
  git -C "$LIVE" worktree remove "$WT"
  git -C "$LIVE" branch -d "$branch"
  [[ -d "$HOME/gbrain-baseline" ]] && git -C "$LIVE" worktree remove --force "$HOME/gbrain-baseline"
  say "removed $WT, $branch and the baseline worktree"
}

cmd_rollback() {
  local tag="${1:-$(git -C "$LIVE" tag -l 'backup/pre-upgrade-*' --sort=-creatordate | head -1)}"
  [[ -n "$tag" ]] || die "no backup tag found"
  [[ -z "$(git -C "$LIVE" status --porcelain)" ]] || die "$LIVE is dirty"
  warn "Rolling $LIVE master back to $tag (current HEAD kept as tag rollback/from-$(date +%Y%m%d-%H%M))"
  git -C "$LIVE" tag "rollback/from-$(date +%Y%m%d-%H%M)" master
  launchctl bootout "gui/$(id -u)/com.gbrain.autopilot" 2>/dev/null || true
  git -C "$LIVE" reset -q --hard "$tag"
  (cd "$LIVE" && bun install >/dev/null)
  gbrain autopilot --install --repo "$BRAIN_REPO" >/dev/null 2>&1 || warn "autopilot reinstall failed"
  say "Now at $(installed_version). Note: DB migrations are forward-only; an older CLI usually tolerates a newer schema, but check: gbrain doctor"
}

case "${1:-}" in
  status)   shift; cmd_status "$@";;
  prepare)  shift; cmd_prepare "$@";;
  verify)   shift; cmd_verify "$@";;
  cutover)  shift; cmd_cutover "$@";;
  check)    shift; cmd_live_checks "$@";;
  push)     shift; cmd_push "$@";;
  cleanup)  shift; cmd_cleanup "$@";;
  rollback) shift; cmd_rollback "$@";;
  *) sed -n '2,23p' "$0"; exit 64;;
esac
