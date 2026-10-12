#!/usr/bin/env bash
# Live validation driver for branch fm/firstmate-learnings-convergence-20261012
# (commit cd16170d "Land restored fleet learnings").
#
# Builds a DISPOSABLE fleet seeded with the real repo history and drives the
# real product scripts (bin/fm-update.sh, bin/fm-session-start.sh) from the
# gate worktree against it. Nothing outside $FLEET (a mktemp dir removed on
# exit) and this evidence dir is written.
#
# Fixture models the intent's exact situation:
#   origin/main  = c3ce0ab6 (BASE: #14/#15/#16 already merged)
#   primary      = clone on main at BASE, carrying the restored fleet-learnings
#                  edits UNCOMMITTED in data/learnings.md (the residual state)
#   sm-behind    = secondmate worktree home, detached at 88665125 (pre-#16)
#   sm-dirty     = secondmate worktree home at BASE with the same uncommitted
#                  learnings edits (adversarial: the guard must never land them
#                  by force/stash/reset)
#
# Phases:
#   0. verify the real landed commit artifact in the gate worktree
#   1. reproduce the block: fm-update skips the dirty primary
#   2. land the bytes through the repo's shipping path (branch + commit + PR
#      merge = fast-forward of origin/main); tree goes clean
#   3. convergence delivers: primary + clean home fast-forward, dirty home
#      still skipped with bytes byte-identical, no stash anywhere
#   4. the landed learnings reach the worker-facing session digest
set -uo pipefail

GATE=/home/kirkins/.no-mistakes/worktrees/c3ea402bfbf7/01M4RSY6XNBW5VEHFJM51BCS1Z
EV=/home/kirkins/.no-mistakes/evidence/01M4RSY6XNBW5VEHFJM51BCS1Z
BASE=c3ce0ab6be154cc7e1f5be7b397c06260c4a8ccc
PRE16=88665125
TARGET=cd16170d0230ee79bdfccdcabbc254c9a6850939
BRANCH=fm/firstmate-learnings-convergence-20261012

FLEET=$(mktemp -d "${TMPDIR:-/tmp}/fm-validate-fleet.XXXXXX")
cleanup() { rm -rf "$FLEET"; }
trap cleanup EXIT
mkdir -p "$EV"

RESULTS="$EV/00-results.txt"
: > "$RESULTS"
fails=0
note() { printf '%s\n' "$*" | tee -a "$RESULTS"; }
check() { # check <desc> <rc>
  if [ "$2" -eq 0 ]; then note "PASS: $1"; else note "FAIL: $1"; fails=$((fails+1)); fi
}

# --- fixture ---------------------------------------------------------------

note "=== fixture fleet: $FLEET"

git init -q --bare "$FLEET/origin.git"
git -C "$FLEET/origin.git" symbolic-ref HEAD refs/heads/main
# Seed origin with the REAL history through the change's own branch ref.
git -C "$FLEET/origin.git" fetch -q "$GATE" "+refs/heads/$BRANCH:refs/heads/main"
git -C "$FLEET/origin.git" update-ref refs/heads/main "$BASE"

git clone -q "$FLEET/origin.git" "$FLEET/primary"
git -C "$FLEET/primary" remote set-head origin main >/dev/null 2>&1 || true

# secondmate homes as detached worktrees of the primary (how treehouse leases)
git -C "$FLEET/primary" worktree add -q --detach "$FLEET/sm-behind" "$PRE16"
printf 'sm-behind\n' > "$FLEET/sm-behind/.fm-secondmate-home"
git -C "$FLEET/primary" worktree add -q --detach "$FLEET/sm-dirty" "$BASE"
printf 'sm-dirty\n' > "$FLEET/sm-dirty/.fm-secondmate-home"

# the primary's FM_HOME (separate dir, like the product's own test fixtures)
mkdir -p "$FLEET/home/state" "$FLEET/home/data" "$FLEET/home/config"
touch "$FLEET/home/state/.last-watcher-beat"
{
  printf 'kind=secondmate\n'
  printf 'harness=claude\n'
  printf 'home=%s\n' "$FLEET/sm-behind"
} > "$FLEET/home/state/sm-behind.meta"
{
  printf 'kind=secondmate\n'
  printf 'harness=claude\n'
  printf 'home=%s\n' "$FLEET/sm-dirty"
} > "$FLEET/home/state/sm-dirty.meta"

# the restored fleet-learnings edits as UNCOMMITTED changes (the residual state)
git -C "$GATE" show "$TARGET:data/learnings.md" > "$FLEET/primary/data/learnings.md"
git -C "$GATE" show "$TARGET:data/learnings.md" > "$FLEET/sm-dirty/data/learnings.md"
RESTORED_SHA=$(sha256sum "$FLEET/primary/data/learnings.md" | cut -d' ' -f1)

{
  echo "primary HEAD:      $(git -C "$FLEET/primary" rev-parse --short HEAD) (main)"
  echo "sm-behind HEAD:    $(git -C "$FLEET/sm-behind" rev-parse --short HEAD) (detached, pre-#16)"
  echo "sm-dirty HEAD:     $(git -C "$FLEET/sm-dirty" rev-parse --short HEAD) (detached, at BASE)"
  echo "origin/main:       $(git -C "$FLEET/origin.git" rev-parse --short main)"
  echo "primary status:    $(git -C "$FLEET/primary" status --porcelain)"
  echo "primary diffstat:  $(git -C "$FLEET/primary" diff --stat | tail -1)"
  echo "restored sha256:   $RESTORED_SHA"
} > "$EV/01-fleet-layout.txt"
cat "$EV/01-fleet-layout.txt" >> "$RESULTS"

# --- phase 0: the real landed commit artifact ------------------------------

{
  echo "\$ git -C $GATE log -1 --format='%H %an %s'"
  git -C "$GATE" log -1 --format='%H %an %s'
  echo
  echo "\$ git -C $GATE status --porcelain (empty == clean tree)"
  git -C "$GATE" status --porcelain
  echo "[exit $? - empty output above means clean]"
  echo
  echo "\$ git -C $GATE stash list (empty == bytes were never stashed)"
  git -C "$GATE" stash list
  echo "[end stash list]"
  echo
  echo "\$ git -C $GATE branch --contains $TARGET | grep $BRANCH"
  git -C "$GATE" for-each-ref --format='%(refname) -> %(objectname)' "refs/heads/$BRANCH"
  echo
  echo "\$ git -C $GATE diff --stat $BASE $TARGET"
  git -C "$GATE" diff --stat "$BASE" "$TARGET"
  echo
  echo "\$ git -C $GATE merge-base --is-ancestor $BASE $TARGET; echo \$?"
  if git -C "$GATE" merge-base --is-ancestor "$BASE" "$TARGET"; then echo "0 (TARGET is a descendant of BASE: fast-forwardable)"; else echo "1 (NOT fast-forwardable)"; fi
  echo
  echo "\$ git -C $GATE diff $BASE $TARGET -- data/learnings.md (the landed bytes)"
  git -C "$GATE" diff "$BASE" "$TARGET" -- data/learnings.md
} > "$EV/02-real-commit-artifact.txt" 2>&1

grep -q 'data/learnings.md | 30 ' "$EV/02-real-commit-artifact.txt"
check "phase0: landed diff is exactly data/learnings.md +28/-2" $?
[ -z "$(git -C "$GATE" status --porcelain)" ]
check "phase0: gate worktree at TARGET is clean (no uncommitted residue)" $?
STASH_LEARN=$(git -C "$GATE" stash list --name-only 2>/dev/null | grep -c 'data/learnings.md' || true)
[ "$STASH_LEARN" = "0" ]
check "phase0: no stash entry carries data/learnings.md (bytes were never parked in a stash; the one pre-existing gate stash is unrelated PR-tooling WIP)" $?
git -C "$GATE" merge-base --is-ancestor "$BASE" "$TARGET"
check "phase0: TARGET is a fast-forward descendant of BASE" $?

# --- phase 1: reproduce the block -------------------------------------------

run_update() {
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
      -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS \
      -u NO_MISTAKES_GATE \
      FM_HOME="$FLEET/home" FM_ROOT_OVERRIDE="$FLEET/primary" \
      "$GATE/bin/fm-update.sh" 2>&1
}

PH1=$(run_update)
{
  echo "\$ FM_HOME=$FLEET/home FM_ROOT_OVERRIDE=$FLEET/primary $GATE/bin/fm-update.sh"
  echo "# (primary carries the restored learnings edits UNCOMMITTED)"
  echo
  printf '%s\n' "$PH1"
} > "$EV/03-phase1-block-reproduction.log"

grep -q '^firstmate: skipped: dirty working tree$' <<<"$PH1"
check "phase1: convergence refuses the dirty primary (block reproduced)" $?
grep -q '^secondmate sm-dirty: skipped: dirty working tree$' <<<"$PH1"
check "phase1: dirty secondmate home also skipped" $?
grep -q '^secondmate sm-behind: updated ' <<<"$PH1"
check "phase1: clean behind home still converges to main's tip (BASE)" $?
[ "$(git -C "$FLEET/primary" rev-parse HEAD)" = "$BASE" ]
check "phase1: dirty primary HEAD did not move" $?
[ "$(sha256sum "$FLEET/primary/data/learnings.md" | cut -d' ' -f1)" = "$RESTORED_SHA" ]
check "phase1: primary's uncommitted learnings bytes untouched (not stashed/discarded)" $?
[ -z "$(git -C "$FLEET/primary" stash list)" ]
check "phase1: no stash created in the primary" $?
[ "$(git -C "$FLEET/sm-behind" rev-parse HEAD)" = "$BASE" ]
check "phase1: sm-behind advanced to BASE (received the #16 fix without the learnings)" $?

# --- phase 2: land the bytes through the repo's shipping path ---------------

PH2LOG="$EV/04-phase2-landing.log"
{
  echo "# Landing: branch + commit + push + PR-merge(fast-forward) of origin/main"
  echo "\$ git -C primary checkout -b $BRANCH   (carries the uncommitted bytes)"
  git -C "$FLEET/primary" checkout -b "$BRANCH" 2>&1
  echo
  echo "\$ git -C primary add data/learnings.md && git commit -m 'Land restored fleet learnings'"
  git -C "$FLEET/primary" add data/learnings.md
  git -C "$FLEET/primary" -c user.name='Philip Kirkbride' -c user.email='kirkins@gmail.com' \
    -c commit.gpgsign=false commit -q -m 'Land restored fleet learnings'
  LANDED=$(git -C "$FLEET/primary" rev-parse HEAD)
  echo "landed commit: $LANDED"
  echo
  echo "\$ git -C primary status --porcelain (empty == tree goes clean)"
  git -C "$FLEET/primary" status --porcelain
  echo "[end status]"
  echo
  echo "\$ git -C primary show --stat --oneline -s HEAD"
  git -C "$FLEET/primary" show --stat --oneline -s HEAD
  echo
  echo "\$ git push origin HEAD:refs/heads/$BRANCH  (the PR branch)"
  git -C "$FLEET/primary" push -q "$FLEET/origin.git" "HEAD:refs/heads/$BRANCH" 2>&1
  echo "pushed."
  echo
  echo "\$ origin: fast-forward main to the landed commit (the PR merge)"
  git -C "$FLEET/origin.git" merge-base --is-ancestor main "$LANDED" \
    && git -C "$FLEET/origin.git" update-ref refs/heads/main "$LANDED" \
    && echo "origin/main -> $(git -C "$FLEET/origin.git" rev-parse --short main)"
  echo
  echo "\$ git -C primary checkout main   (back to the tracked branch; tree clean)"
  git -C "$FLEET/primary" checkout -q main 2>&1
  echo "primary HEAD: $(git -C "$FLEET/primary" rev-parse --short HEAD) (main)"
  git -C "$FLEET/primary" status --porcelain
  echo "[end status]"
} > "$PH2LOG" 2>&1

LANDED=$(git -C "$FLEET/primary" rev-parse "refs/heads/$BRANCH")
[ -z "$(git -C "$FLEET/primary" status --porcelain)" ] || true
# tree-clean check happens right after the commit, captured in the log; re-derive:
git -C "$FLEET/primary" checkout -q "$BRANCH" 2>/dev/null
CLEAN_AFTER_COMMIT=$([ -z "$(git -C "$FLEET/primary" status --porcelain)" ] && echo yes || echo no)
git -C "$FLEET/primary" checkout -q main 2>/dev/null
[ "$CLEAN_AFTER_COMMIT" = yes ]
check "phase2: after landing, the working tree is clean" $?
[ "$(git -C "$FLEET/primary" rev-parse "refs/heads/$BRANCH^")" = "$BASE" ]
check "phase2: landed commit is a single clean child of BASE (linear, ff-able)" $?
git -C "$FLEET/primary" diff --quiet "$BRANCH" "$TARGET" -- data/learnings.md
check "phase2: landed data/learnings.md bytes are identical to the restored fleet edits (sha $RESTORED_SHA)" $?
[ "$(git -C "$FLEET/origin.git" rev-parse main)" = "$LANDED" ]
check "phase2: origin/main advanced to the landed commit (PR merged)" $?

# --- phase 3: convergence delivers ------------------------------------------

PH3=$(run_update)
{
  echo "\$ FM_HOME=$FLEET/home FM_ROOT_OVERRIDE=$FLEET/primary $GATE/bin/fm-update.sh"
  echo "# (learnings landed on origin/main; primary back on clean main at BASE)"
  echo
  printf '%s\n' "$PH3"
} > "$EV/05-phase3-convergence-delivery.log"

grep -q '^firstmate: updated ' <<<"$PH3"
check "phase3: the primary fast-forwards to the landed commit" $?
grep -q '^secondmate sm-behind: updated ' <<<"$PH3"
check "phase3: clean behind home fast-forwards too" $?
grep -q '^secondmate sm-dirty: skipped: dirty working tree$' <<<"$PH3"
check "phase3: adversarial: dirty home still refused, never forced" $?
grep -q '^reread-firstmate: no' <<<"$PH3"
check "phase3: learnings-only advance leaves instruction surface unchanged (reread-firstmate: no)" $?
[ "$(git -C "$FLEET/primary" rev-parse HEAD)" = "$LANDED" ]
check "phase3: primary HEAD == landed commit" $?
[ "$(git -C "$FLEET/sm-behind" rev-parse HEAD)" = "$LANDED" ]
check "phase3: sm-behind HEAD == landed commit" $?
grep -q 'Hermes communication surfaces (2026-10-12)' "$FLEET/primary/data/learnings.md"
check "phase3: primary's data/learnings.md now carries the landed Hermes learning" $?
grep -q 'Hermes communication surfaces (2026-10-12)' "$FLEET/sm-behind/data/learnings.md"
check "phase3: converged home's data/learnings.md carries the landed learning" $?
grep -q "exact-pane process proof" "$FLEET/sm-behind/bin/backends/herdr.sh" 2>/dev/null \
  || git -C "$FLEET/sm-behind" diff --name-only "$PRE16" HEAD | grep -q '^bin/backends/herdr.sh$'
check "phase3: converged home received the merged #16 fix bytes (bin/backends/herdr.sh)" $?
git -C "$FLEET/sm-behind" diff --name-only "$PRE16" HEAD | grep -q '^data/learnings.md$'
check "phase3: converged home received the tracked learnings file in the same pass" $?
[ -z "$(git -C "$FLEET/primary" status --porcelain)" ]
check "phase3: primary tree clean after convergence" $?
[ -z "$(git -C "$FLEET/sm-behind" status --porcelain)" ]
check "phase3: converged home tree clean after convergence" $?
[ "$(git -C "$FLEET/sm-dirty" rev-parse HEAD)" = "$BASE" ]
check "phase3: adversarial: dirty home HEAD never moved" $?
[ "$(sha256sum "$FLEET/sm-dirty/data/learnings.md" | cut -d' ' -f1)" = "$RESTORED_SHA" ]
check "phase3: adversarial: dirty home's learnings bytes byte-identical, never discarded" $?
[ -z "$(git -C "$FLEET/primary" stash list)" ] && [ -z "$(git -C "$FLEET/sm-behind" stash list)" ] && [ -z "$(git -C "$FLEET/sm-dirty" stash list)" ]
check "phase3: no stash created in any fleet repo" $?

{
  echo "# guard proof (adversarial home sm-dirty across both passes)"
  echo "sm-dirty HEAD:  $(git -C "$FLEET/sm-dirty" rev-parse HEAD) (expected $BASE)"
  echo "learnings sha:  $(sha256sum "$FLEET/sm-dirty/data/learnings.md" | cut -d' ' -f1)"
  echo "expected sha:   $RESTORED_SHA"
  echo "stash lists:    primary=[$(git -C "$FLEET/primary" stash list)] sm-behind=[$(git -C "$FLEET/sm-behind" stash list)] sm-dirty=[$(git -C "$FLEET/sm-dirty" stash list)]"
  echo "sm-dirty reflog (no reset/merge entries expected):"
  git -C "$FLEET/sm-dirty" reflog -5
} > "$EV/06-guard-no-discard-proof.txt" 2>&1

# --- phase 4: landed learnings reach the worker-facing digest ---------------

PH4LOG="$EV/07-phase4-session-digest.log"
mkdir -p "$FLEET/primary/state"
timeout 150 env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS \
    -u NO_MISTAKES_GATE \
    FM_HOME="$FLEET/primary" FM_ROOT_OVERRIDE="$FLEET/primary" \
    "$GATE/bin/fm-session-start.sh" > "$PH4LOG.raw" 2>&1
PH4RC=$?
{
  echo "\$ FM_HOME=$FLEET/primary FM_ROOT_OVERRIDE=$FLEET/primary $GATE/bin/fm-session-start.sh"
  echo "# (the converged primary home; exit=$PH4RC)"
  echo
  cat "$PH4LOG.raw"
} > "$PH4LOG"
rm -f "$PH4LOG.raw"

# The CONTEXT digest section must print the landed learnings to the worker.
awk '/^CONTEXT$/{flag=1} /^NEXT STEP$/{flag=0} flag' "$PH4LOG" > "$EV/08-digest-context-section.txt"
if grep -q 'data/learnings.md' "$EV/08-digest-context-section.txt" \
  && grep -q 'Hermes communication surfaces (2026-10-12)' "$EV/08-digest-context-section.txt"; then
  check "phase4: session digest CONTEXT section renders the landed learnings to the worker" 0
else
  check "phase4: session digest CONTEXT section renders the landed learnings to the worker" 1
fi

note ""
note "=== overall: $fails failing assertion(s)"
exit $(( fails > 0 ? 1 : 0 ))
