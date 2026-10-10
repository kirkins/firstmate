#!/usr/bin/env bash
# Behavior tests for bin/fm-heavy-slot.sh, the memory-heavy job turnstile.
#
# Every case drives the executable interface against a scratch home, never the
# record file's bytes: acquire/release/heartbeat/status are the public surface
# the fleet's workers and firstmate use, so the guarantees tested here are the
# ones the brief scaffold teaches (one holder, named refusal, wait-then-retry,
# takeover after heartbeat expiry, idempotent release, loud staleness).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLOT="$ROOT/bin/fm-heavy-slot.sh"
TMP_ROOT=$(fm_test_tmproot fm-heavy-slot)

# make_home <name>: a scratch home plus its own machine-state root, the XDG
# location the machine-wide turnstile coordinates in.
make_home() {
  local home
  home="$TMP_ROOT/$1"
  mkdir -p "$home/xdg"
  printf '%s\n' "$home"
}

# slot <home> <args...>: run the turnstile as one home's crew against that
# scratch machine state, capturing stdout and stderr separately and the exit
# code in SLOT_STATUS.
slot() {
  local home=$1
  shift
  SLOT_STDOUT=$(FM_HOME="$home" XDG_STATE_HOME="$home/xdg" "$SLOT" "$@" 2>"$TMP_ROOT/stderr")
  SLOT_STATUS=$?
  SLOT_STDERR=$(cat "$TMP_ROOT/stderr")
}

test_usage_is_loud_and_closed_set() {
  local home out status
  home=$(make_home usage)
  out=$(FM_HOME="$home" XDG_STATE_HOME="$home/xdg" "$SLOT" 2>&1); status=$?
  expect_code 2 "$status" "no subcommand must be a usage error"
  assert_contains "$out" "fm-heavy-slot.sh acquire" "usage did not render the command surface"
  out=$(FM_HOME="$home" XDG_STATE_HOME="$home/xdg" "$SLOT" acquire bad-id 2>&1); status=$?
  expect_code 2 "$status" "a missing --estimate must be a usage error"
  assert_contains "$out" "--estimate requires a positive integer" "missing estimate refusal did not explain the contract"
  out=$(FM_HOME="$home" XDG_STATE_HOME="$home/xdg" "$SLOT" acquire 'bad id' --estimate 100 2>&1); status=$?
  expect_code 2 "$status" "a task id with a space must be a usage error"
  out=$(FM_HOME="$home" XDG_STATE_HOME="$home/xdg" "$SLOT" acquire t --estimate 0 2>&1); status=$?
  expect_code 2 "$status" "a zero estimate must be a usage error"
  out=$(FM_HOME="$home" XDG_STATE_HOME="$home/xdg" "$SLOT" acquire t --estimate 100 --expiry nope 2>&1); status=$?
  expect_code 2 "$status" "a non-integer expiry must be a usage error"
  out=$(FM_HOME="$home" XDG_STATE_HOME="$home/xdg" "$SLOT" acquire t --estimate 0900 2>&1); status=$?
  expect_code 2 "$status" "a leading-zero estimate must be a usage error, never an octal crash"
  out=$(FM_HOME="$home" XDG_STATE_HOME="$home/xdg" "$SLOT" acquire t --estimate 100 --expiry 0900 2>&1); status=$?
  expect_code 2 "$status" "a leading-zero expiry must be a usage error, never a persisted octal field"
  slot "$home" status
  assert_contains "$SLOT_STDOUT" "free" "refused numeric inputs must leave no hold behind"
  slot "$home" acquire stray-task --estimate 100
  expect_code 0 "$SLOT_STATUS" "setup acquire for the stray-argument checks must succeed"
  out=$(FM_HOME="$home" XDG_STATE_HOME="$home/xdg" "$SLOT" release stray-task --extra 2>&1); status=$?
  expect_code 2 "$status" "a stray release argument must be a usage error"
  slot "$home" status
  assert_contains "$SLOT_STDOUT" "held task=stray-task" "a refused release must not clear the live slot"
  out=$(FM_HOME="$home" XDG_STATE_HOME="$home/xdg" "$SLOT" heartbeat stray-task stray 2>&1); status=$?
  expect_code 2 "$status" "a stray heartbeat argument must be a usage error"
  slot "$home" release stray-task
  expect_code 0 "$SLOT_STATUS" "holder cleanup after the stray-argument checks must succeed"
  pass "fm-heavy-slot.sh: usage and value validation refuse loudly"
}

test_concurrent_acquire_admits_exactly_one_holder() {
  local home a b winners=0 holder_line
  home=$(make_home concurrent)
  ( FM_HOME="$home" XDG_STATE_HOME="$home/xdg" "$SLOT" acquire worker-a --estimate 100 >/dev/null 2>&1; echo $? >"$TMP_ROOT/race-a.rc" ) &
  ( FM_HOME="$home" XDG_STATE_HOME="$home/xdg" "$SLOT" acquire worker-b --estimate 100 >/dev/null 2>&1; echo $? >"$TMP_ROOT/race-b.rc" ) &
  wait
  a=$(cat "$TMP_ROOT/race-a.rc")
  b=$(cat "$TMP_ROOT/race-b.rc")
  [ "$a" = 0 ] && winners=$((winners + 1))
  [ "$b" = 0 ] && winners=$((winners + 1))
  expect_code 1 "$winners" "exactly one concurrent acquire must win (exits: a=$a b=$b)"
  if [ "$a" = 0 ]; then
    expect_code 6 "$b" "the losing concurrent acquire must refuse (exits: a=$a b=$b)"
  else
    expect_code 0 "$b" "one concurrent acquire must win when the other refuses (exits: a=$a b=$b)"
    expect_code 6 "$a" "the losing concurrent acquire must refuse (exits: a=$a b=$b)"
  fi
  slot "$home" status
  holder_line=$SLOT_STDOUT
  assert_contains "$holder_line" "state=live" "post-race status is not a live hold"
  case "$holder_line" in
    *"task=worker-a"* | *"task=worker-b"*) : ;;
    *) fail "post-race status names neither race winner: $holder_line" ;;
  esac
  pass "fm-heavy-slot.sh: concurrent acquire refuses the second caller"
}

test_held_refusal_names_the_holder() {
  local home
  home=$(make_home refusal)
  slot "$home" acquire holder-task --estimate 2048
  expect_code 0 "$SLOT_STATUS" "first acquire must succeed"
  slot "$home" acquire waiter-task --estimate 512
  expect_code 6 "$SLOT_STATUS" "second acquire must refuse fast"
  assert_contains "$SLOT_STDERR" "held by task 'holder-task'" "refusal did not name the current holder"
  assert_contains "$SLOT_STDERR" "estimate 2048MB" "refusal did not carry the holder's estimate"
  assert_contains "$SLOT_STDERR" "retry acquire later" "refusal did not teach the wait-and-retry contract"
  pass "fm-heavy-slot.sh: a held slot refuses with the holder named"
}

test_acquire_output_names_the_cap_wrapper() {
  local home
  home=$(make_home wrapper)
  slot "$home" acquire cap-task --estimate 4000
  expect_code 0 "$SLOT_STATUS" "acquire must succeed"
  assert_contains "$SLOT_STDOUT" "systemd-run --user --scope -p MemoryMax=4096M --" \
    "acquire output did not name the rounded cap wrapper (4000MB must round up to 4096M)"
  assert_contains "$SLOT_STDOUT" "release cap-task" "acquire output did not remind the caller to release"
  case "$SLOT_STDOUT" in
    *"parallelism bounded: no more than -j"[1-8]*) : ;;
    *) fail "acquire output did not bound job parallelism: $SLOT_STDOUT" ;;
  esac
  pass "fm-heavy-slot.sh: acquire output carries the cap wrapper and release"
}

test_release_hint_is_copy_safe() {
  local home spaced out release_line
  home=$(make_home "hint home")
  spaced="$home/hint dir"
  mkdir -p "$spaced"
  ln -s "$ROOT/bin/fm-heavy-slot.sh" "$spaced/fm-heavy-slot.sh"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$spaced/fm-wake-lib.sh"
  ln -s "$ROOT/bin/fm-path-lib.sh" "$spaced/fm-path-lib.sh"
  export XDG_STATE_HOME="$home/xdg"
  out=$(FM_HOME="$home" "$spaced/fm-heavy-slot.sh" acquire hint-task --estimate 100 2>/dev/null)
  release_line=$(printf '%s\n' "$out" | sed -n 's/^release immediately after the job: //p')
  [ -n "$release_line" ] || { unset XDG_STATE_HOME; fail "acquire output did not print a release command"; }
  out=$(eval "$release_line" 2>/dev/null)
  unset XDG_STATE_HOME
  assert_contains "$out" "released: task=hint-task" \
    "the printed release command is not safe to copy verbatim under a spaced script path"
  pass "fm-heavy-slot.sh: the printed release command survives a spaced script path"
}

test_slot_is_machine_wide_across_homes() {
  local home_a home_b shared out status
  home_a=$(make_home machine-a)
  home_b=$(make_home machine-b)
  shared="$TMP_ROOT/machine-shared"
  mkdir -p "$shared"
  FM_HOME="$home_a" XDG_STATE_HOME="$shared" "$SLOT" acquire crew-a --estimate 100 >/dev/null 2>&1
  expect_code 0 "$?" "the first home's acquire must succeed"
  out=$(FM_HOME="$home_b" XDG_STATE_HOME="$shared" "$SLOT" acquire crew-b --estimate 100 2>&1); status=$?
  expect_code 6 "$status" "a second home's acquire must refuse on the one machine slot"
  assert_contains "$out" "held by task 'crew-a'" "cross-home refusal did not name the holder"
  out=$(FM_HOME="$home_b" XDG_STATE_HOME="$shared" "$SLOT" status 2>/dev/null)
  assert_contains "$out" "held task=crew-a" "the second home must see the first home's hold"
  FM_HOME="$home_b" XDG_STATE_HOME="$shared" "$SLOT" release crew-a >/dev/null 2>&1
  expect_code 0 "$?" "the second home must clear the first home's hold on the shared record"
  out=$(FM_HOME="$home_a" XDG_STATE_HOME="$shared" "$SLOT" status 2>/dev/null)
  assert_contains "$out" "free" "both homes must see the shared slot free again"
  pass "fm-heavy-slot.sh: two homes contend on one machine-wide slot"
}

test_release_is_scoped_and_idempotent() {
  local home
  home=$(make_home release)
  slot "$home" acquire owner-task --estimate 100
  expect_code 0 "$SLOT_STATUS" "acquire must succeed"
  slot "$home" release outsider-task
  expect_code 6 "$SLOT_STATUS" "release by a non-holder must refuse a live slot"
  assert_contains "$SLOT_STDERR" "held by task 'owner-task'" "release refusal did not name the holder"
  slot "$home" release owner-task
  expect_code 0 "$SLOT_STATUS" "release by the holder must succeed"
  assert_contains "$SLOT_STDOUT" "released: task=owner-task" "release did not report what it cleared"
  slot "$home" release owner-task
  expect_code 0 "$SLOT_STATUS" "a second release must be an idempotent no-op"
  assert_contains "$SLOT_STDOUT" "free" "idempotent release did not report the free slot"
  pass "fm-heavy-slot.sh: release is holder-scoped and idempotent"
}

test_expiry_allows_takeover_and_surfaces_loudly() {
  local home
  home=$(make_home expiry)
  slot "$home" acquire gone-task --estimate 100 --expiry 1
  expect_code 0 "$SLOT_STATUS" "acquire with a short expiry must succeed"
  sleep 2
  slot "$home" status
  expect_code 0 "$SLOT_STATUS" "status must succeed on a stale slot"
  assert_contains "$SLOT_STDOUT" "state=stale" "expired holder did not surface as stale"
  assert_contains "$SLOT_STDOUT" "task=gone-task" "stale status did not name the holder"
  assert_contains "$SLOT_STDERR" "stale" "staleness was not surfaced loudly on stderr"
  slot "$home" acquire fresh-task --estimate 100
  expect_code 0 "$SLOT_STATUS" "takeover of an expired slot must succeed"
  assert_contains "$SLOT_STDERR" "taking over the stale heavy slot held by task 'gone-task'" \
    "takeover did not announce the displaced holder"
  slot "$home" status
  assert_contains "$SLOT_STDOUT" "task=fresh-task" "post-takeover status did not name the new holder"
  assert_contains "$SLOT_STDOUT" "state=live" "post-takeover status is not live"
  slot "$home" release fresh-task
  expect_code 0 "$SLOT_STATUS" "release after takeover must succeed"
  pass "fm-heavy-slot.sh: heartbeat expiry surfaces loudly and allows takeover"
}

test_heartbeat_refreshes_only_the_holder() {
  local home
  home=$(make_home heartbeat)
  slot "$home" acquire beat-task --estimate 100
  expect_code 0 "$SLOT_STATUS" "acquire must succeed"
  slot "$home" heartbeat beat-task
  expect_code 0 "$SLOT_STATUS" "holder heartbeat must succeed"
  assert_contains "$SLOT_STDOUT" "task=beat-task" "heartbeat did not confirm the holder"
  slot "$home" heartbeat other-task
  expect_code 6 "$SLOT_STATUS" "a non-holder heartbeat must refuse"
  slot "$home" release beat-task >/dev/null
  slot "$home" heartbeat beat-task
  expect_code 1 "$SLOT_STATUS" "heartbeat with no slot held must report the miss"
  pass "fm-heavy-slot.sh: heartbeat refreshes the holder and refuses others"
}

test_status_reports_free_and_live_holds() {
  local home
  home=$(make_home status)
  slot "$home" status
  expect_code 0 "$SLOT_STATUS" "status on a free slot must succeed"
  assert_contains "$SLOT_STDOUT" "free" "an unheld slot did not report free"
  slot "$home" acquire stat-task --estimate 256 --expiry 600
  expect_code 0 "$SLOT_STATUS" "acquire must succeed"
  slot "$home" status
  assert_contains "$SLOT_STDOUT" "held task=stat-task" "status did not report the holder identity"
  assert_contains "$SLOT_STDOUT" "estimate=256MB" "status did not report the estimate"
  assert_contains "$SLOT_STDOUT" "state=live" "status did not report a live hold"
  case "$SLOT_STDOUT" in
    *"expires_in="*[0-9]"s"*) : ;;
    *) fail "status did not report the remaining window: $SLOT_STDOUT" ;;
  esac
  slot "$home" release stat-task >/dev/null
  slot "$home" status
  assert_contains "$SLOT_STDOUT" "free" "a released slot did not report free"
  pass "fm-heavy-slot.sh: status reports free, held, and window state"
}

test_usage_is_loud_and_closed_set
test_concurrent_acquire_admits_exactly_one_holder
test_slot_is_machine_wide_across_homes
test_held_refusal_names_the_holder
test_acquire_output_names_the_cap_wrapper
test_release_hint_is_copy_safe
test_release_is_scoped_and_idempotent
test_expiry_allows_takeover_and_surfaces_loudly
test_heartbeat_refreshes_only_the_holder
test_status_reports_free_and_live_holds
