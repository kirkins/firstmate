#!/usr/bin/env bash
# fm-spend-lib.sh - the away-posture spend cap's active-work counting.
#
# ONE OWNER of one question: does a live ordinary task in this home count
# against the away record's spend_max_concurrent_workers? bin/fm-afk-contract.sh
# owns the record and its fields; bin/fm-spawn.sh owns the refusal that enforces
# the cap. This library owns only the counting classification, so the cap
# measures ACTIVE COMPUTE rather than live panes: a worker that is working,
# validating, or driving costs a cap slot, while an open pane whose task waits
# on something other than compute costs nothing against the cap.
#
# Counting rule (fm_spend_task_counts_active):
#   free, no cap slot       - declared external wait: fm-crew-state.sh reads
#                             `paused` (a declared paused: wait), `blocked`
#                             (a declared blocked: wait), or `parked` (parked
#                             at a gate or on a captain decision);
#                           - captain-held transfer: bin/fm-captain-hold.sh's
#                             `open` proves an active hold, so the work sits
#                             with the captain rather than in the pane;
#                           - terminal state: fm-crew-state.sh reads `done` or
#                             `failed`, verdicts whose run is over and whose
#                             task record awaits ordinary cleanup or
#                             attention. The classifier never reads `blocked`
#                             or `failed` while a run is executing or a pane
#                             is busy - executing runs read `working` and
#                             supersede the log, and the pane fallback reads
#                             the status verb only after an exact idle - so
#                             each definitive not-computing verdict is itself
#                             positive proof.
#   counts, one cap slot    - `working` (working, validating, and driving all
#                             read as working there), which outranks a hold:
#                             while the worker is provably computing, the slot
#                             is spent even when a decision waits behind it;
#                           - everything else, deliberately: `unknown`, an
#                             unreadable state line, or a failed read all
#                             count, so the cap fails closed. A task is free
#                             only on positive proof it is not computing,
#                             and `unknown` is the absence of a verdict: a
#                             wedged daemon or unreadable pane can hide live
#                             compute.
#
# The state read is bin/fm-crew-state.sh's current-state classification,
# reused verbatim through its public one-line output, and the hold read is
# bin/fm-captain-hold.sh's `open` exit status: no second state machine lives
# here, and no pane, log, run record, or backlog row is read directly.
# docs/configuration.md's away-posture spend cap section records this rule and
# the recorded default.
#
# The two binaries are overridable so tests can stub the state and hold
# verdicts without a real worktree, backlog, or no-mistakes install, through
# the same seam fm-classify-lib.sh's FM_CREW_STATE_BIN gives its tests: an
# explicit FM_SPEND_CREW_STATE_BIN wins, then FM_CREW_STATE_BIN, then the
# sibling script.

_FM_SPEND_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd 2>/dev/null)" || _FM_SPEND_LIB_DIR="."
FM_SPEND_CREW_STATE_BIN="${FM_SPEND_CREW_STATE_BIN:-${FM_CREW_STATE_BIN:-$_FM_SPEND_LIB_DIR/fm-crew-state.sh}}"
FM_SPEND_CAPTAIN_HOLD_BIN="${FM_SPEND_CAPTAIN_HOLD_BIN:-$_FM_SPEND_LIB_DIR/fm-captain-hold.sh}"

# fm_spend_task_counts_active <state-dir> <task-id>
# Exit 0: the task counts against the away spend cap. Exit 1: the task is
# proven idle for cap purposes; its pane may still be open, because a pane is
# not a slot. Never exits with any other status and never writes to the
# terminal, so the caller's count arithmetic stays the only output.
fm_spend_task_counts_active() {
  local state_dir=$1 id=$2 line st
  line=$(FM_STATE_OVERRIDE="$state_dir" "$FM_SPEND_CREW_STATE_BIN" "$id" </dev/null 2>/dev/null) || return 0
  line=${line%%$'\n'*}
  st=${line#state: }
  st=${st%% *}
  case "$st" in
    working) return 0 ;;
    paused | blocked | parked | done | failed) return 1 ;;
  esac
  # unknown or an unrecognized line: the one remaining proven-idle class is
  # a captain-held transfer, and only its positive `open` proof frees the
  # slot. Every other outcome, including a hold read that fails or cannot
  # answer, keeps it, so the count fails closed.
  if FM_STATE_OVERRIDE="$state_dir" "$FM_SPEND_CAPTAIN_HOLD_BIN" open "$id" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}
