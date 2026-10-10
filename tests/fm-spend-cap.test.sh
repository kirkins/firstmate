#!/usr/bin/env bash
# tests/fm-spend-cap.test.sh - the away-posture spend cap's active-work
# counting (bin/fm-spend-lib.sh): the classification matrix that decides
# whether a live ordinary task costs a cap slot. Working, validating, and
# driving count; a declared external wait (paused, or parked at a gate), a
# captain-held transfer, and a done-awaiting-cleanup terminal state do not;
# blocked, failed, unknown, and every unreadable or failing read count
# conservatively. The matrix is exercised through the library's public
# function with the state and hold binaries stubbed through the same override
# seam bin/fm-classify-lib.sh exposes (FM_CREW_STATE_BIN), never by asserting
# implementation source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPEND_LIB="$ROOT/bin/fm-spend-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-spend-cap-tests)

# A stub bin/fm-crew-state.sh: the task id is $1 and the verdict comes from a
# per-task file under the stub dir, holding one of a state word (printed in
# the real one-line output shape), or EMPTY (a blank line), GARBAGE (a line
# with no state shape), or FAIL (no output, nonzero exit). It records the
# FM_STATE_OVERRIDE it was handed so the plumbing is pinned too.
make_crew_state_stub() {  # <stub-path>
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${FM_STATE_OVERRIDE:-unset}" > "${STUB_DIR:?}/last-state-override"
f="$STUB_DIR/${1:?}.state"
[ -f "$f" ] || exit 1
v=$(cat "$f")
case "$v" in
  FAIL) exit 1 ;;
  EMPTY) printf '\n' ;;
  GARBAGE) printf 'not a state line at all\n' ;;
  *) printf 'state: %s · source: status-log · stubbed\n' "$v" ;;
esac
STUB
  chmod +x "$1"
}

# A stub bin/fm-captain-hold.sh: `open <id>` exits 0 while a hold marker file
# exists, 2 while an error marker exists (the unreadable-backlog case), and 1
# otherwise, matching the real exit contract.
make_captain_hold_stub() {  # <stub-path>
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = open ] || exit 2
id="${2:?}"
[ -f "$STUB_DIR/$id.holderr" ] && exit 2
[ -f "$STUB_DIR/$id.held" ] && exit 0
exit 1
STUB
  chmod +x "$1"
}

# Build one classified-task fixture: a state dir with the task's meta plus the
# stub verdict files, and the sourced library ready to classify it.
# Sets STUB_DIR, STATE_DIR, and STUB_CREW/STUB_HOLD paths for the caller.
make_fixture() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/stub"
  printf 'window=fm-task-x\nkind=ship\n' > "$dir/state/task-x.meta"
  STUB_DIR="$dir/stub"
  STATE_DIR="$dir/state"
  STUB_CREW="$dir/crew-state-stub.sh"
  STUB_HOLD="$dir/hold-stub.sh"
  make_crew_state_stub "$STUB_CREW"
  make_captain_hold_stub "$STUB_HOLD"
}

# Classify task-x under a fresh source of the library with the stubs bound,
# printing counts or free for the assertion helpers.
classify() {  # -> prints "counts" or "free"
  (
    FM_SPEND_CREW_STATE_BIN="$STUB_CREW"
    FM_SPEND_CAPTAIN_HOLD_BIN="$STUB_HOLD"
    export FM_SPEND_CREW_STATE_BIN FM_SPEND_CAPTAIN_HOLD_BIN STUB_DIR
    # shellcheck source=bin/fm-spend-lib.sh
    . "$SPEND_LIB"
    if fm_spend_task_counts_active "$STATE_DIR" task-x; then
      printf 'counts\n'
    else
      printf 'free\n'
    fi
  )
}

expect_counts() {  # <label>
  local label=$1
  [ "$(classify)" = counts ] || fail "$label should count against the cap (got: $(classify))"
}

expect_free() {  # <label>
  local label=$1
  [ "$(classify)" = free ] || fail "$label should be free against the cap (got: $(classify))"
}

test_working_validating_and_driving_count() {
  make_fixture working
  # Validating (a live run-step) and driving (a busy pane) both read as
  # `working` in bin/fm-crew-state.sh's vocabulary, so the one token carries
  # all three verdicts here; the distinction lives upstream, not in counting.
  printf 'working\n' > "$STUB_DIR/task-x.state"
  expect_counts 'a working, validating, or driving task'
  pass "working, validating, and driving tasks each count as active compute"
}

test_declared_waits_are_free() {
  make_fixture waits
  printf 'paused\n' > "$STUB_DIR/task-x.state"
  expect_free 'a declared paused: external wait'
  printf 'parked\n' > "$STUB_DIR/task-x.state"
  expect_free 'a task parked at a gate or captain decision'
  pass "declared external waits cost their panes but no cap slot"
}

test_done_awaiting_cleanup_is_free() {
  make_fixture done-terminal
  printf 'done\n' > "$STUB_DIR/task-x.state"
  expect_free 'a done-awaiting-cleanup terminal state'
  pass "a done terminal state whose record awaits cleanup costs no cap slot"
}

test_captain_held_transfer_is_free() {
  make_fixture held
  printf 'unknown\n' > "$STUB_DIR/task-x.state"
  expect_counts 'an unknown task with no hold still counts'
  : > "$STUB_DIR/task-x.held"
  expect_free 'a captain-held transfer frees an otherwise-counting task'
  printf 'blocked\n' > "$STUB_DIR/task-x.state"
  expect_free 'a captain-held transfer frees a blocked task'
  rm -f "$STUB_DIR/task-x.held"
  printf 'blocked\n' > "$STUB_DIR/task-x.state"
  expect_counts 'a blocked task with no hold counts'
  pass "a captain-held transfer costs no cap slot, and only the hold's positive proof frees it"
}

test_working_outranks_a_hold() {
  make_fixture held-working
  printf 'working\n' > "$STUB_DIR/task-x.state"
  : > "$STUB_DIR/task-x.held"
  expect_counts 'a working task stays counted even while held for the captain'
  pass "positive compute evidence outranks a captain hold for cap counting"
}

test_unreadable_states_count_conservatively() {
  make_fixture unreadable
  printf 'FAIL\n' > "$STUB_DIR/task-x.state"
  expect_counts 'a failed state read'
  printf 'GARBAGE\n' > "$STUB_DIR/task-x.state"
  expect_counts 'an unparseable state line'
  printf 'EMPTY\n' > "$STUB_DIR/task-x.state"
  expect_counts 'an empty state line'
  rm -f "$STUB_DIR/task-x.state"
  expect_counts 'a missing state verdict'
  printf 'unknown\n' > "$STUB_DIR/task-x.state"
  expect_counts 'an unknown state'
  printf 'failed\n' > "$STUB_DIR/task-x.state"
  expect_counts 'a failed terminal state'
  : > "$STUB_DIR/task-x.holderr"
  expect_counts 'an unknown state whose hold read errors'
  pass "unreadable, unknown, failed, and erroring reads all count, so the cap fails closed"
}

test_state_read_receives_the_callers_state_dir() {
  make_fixture plumbing
  printf 'paused\n' > "$STUB_DIR/task-x.state"
  expect_free 'a paused task in the fixture'
  [ "$(cat "$STUB_DIR/last-state-override" 2>/dev/null)" = "$STATE_DIR" ] \
    || fail "the state read did not receive the caller's state dir as FM_STATE_OVERRIDE: $(cat "$STUB_DIR/last-state-override" 2>/dev/null)"
  pass "the classification reads the caller's state dir through FM_STATE_OVERRIDE"
}

test_spend_override_wins_over_the_classify_seam() {
  make_fixture seam
  printf 'paused\n' > "$STUB_DIR/task-x.state"
  (
    FM_SPEND_CREW_STATE_BIN="$STUB_CREW"
    FM_CREW_STATE_BIN=/nonexistent/fm-crew-state.sh
    FM_SPEND_CAPTAIN_HOLD_BIN="$STUB_HOLD"
    export FM_SPEND_CREW_STATE_BIN FM_CREW_STATE_BIN FM_SPEND_CAPTAIN_HOLD_BIN STUB_DIR
    # shellcheck source=bin/fm-spend-lib.sh
    . "$SPEND_LIB"
    if fm_spend_task_counts_active "$STATE_DIR" task-x; then
      fail "FM_SPEND_CREW_STATE_BIN lost to FM_CREW_STATE_BIN: a paused task counted"
    fi
  ) || fail "the override-precedence probe failed"
  pass "an explicit FM_SPEND_CREW_STATE_BIN wins over the shared FM_CREW_STATE_BIN seam"
}

test_working_validating_and_driving_count
test_declared_waits_are_free
test_done_awaiting_cleanup_is_free
test_captain_held_transfer_is_free
test_working_outranks_a_hold
test_unreadable_states_count_conservatively
test_state_read_receives_the_callers_state_dir
test_spend_override_wins_over_the_classify_seam
