#!/usr/bin/env bash
# fm-heavy-slot.sh - single-slot turnstile for memory-heavy jobs machine-wide.
#
# WHY. Multiple agents on one machine can each run a memory-heavy build, test
# suite, or lint walk, and the local-memory-exhaustion evidence in
# data/learnings.md shows what happens when they overlap: the machine OOMs and
# takes unrelated work down with it. The captain's chosen direction is flexible
# agent count with heavy jobs taking turns, so this turnstile is the mechanism:
# exactly one memory-heavy job may run at a time on this machine, across every
# home's fleet - primary and secondmate alike - while the number of agents
# stays uncapped. It coordinates; it never enforces agent counts and never
# manages cgroups beyond printing the documented wrapper.
#
# CONTRACT.
#   - Slot record: ${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/heavy-slot
#     (directory created mode 0700), one line
#     "<task-id>\t<pid>\t<estimate-mb>\t<heartbeat-epoch>\t<expiry-seconds>",
#     written atomically (temp file + rename) with every mutation serialized by
#     the command lock .heavy-slot.lock beside it through the portable lock
#     helpers (bin/fm-wake-lib.sh, the same no-flock shape bin/fm-lease.sh
#     uses), so concurrent acquires from sibling workers serialize and exactly
#     one wins. The coordination scope is the whole machine, not one home:
#     every home's crews resolve the same canonical state root, so workers
#     spawned by any home contend on this one slot.
#   - Holder identity is the task id the caller passes; the recorded pid is the
#     acquiring shell, kept for audit and display, never for liveness: acquire
#     is a short-lived CLI whose pid is gone before the job runs, so staleness
#     is judged only by the heartbeat window.
#   - Staleness: a holder is stale when now - heartbeat-epoch exceeds the
#     recorded expiry window. acquire refuses fast (exit 6) while a live holder
#     exists, naming the holder so the caller can declare a wait, and takes
#     over a stale holder with a loud note. heartbeat refreshes the window for
#     the recorded holder only. release is idempotent and clears only for the
#     recorded holder or an expired one; a non-holder never clears a live slot.
#   - No daemon, no scheduler, no polling loop: state changes only when a
#     worker or firstmate runs this command, and status is the surface
#     firstmate and the watcher read for holder and staleness.
#   - The memory cap is advisory coordination, not enforcement: acquire prints
#     the mandatory cap wrapper (systemd-run --user --scope with the estimate
#     rounded up to the next 256 MiB) and a bounded parallelism hint, and warns
#     when systemd-run is unavailable because the cap then cannot be applied.
#
# Usage:
#   fm-heavy-slot.sh acquire <task-id> --estimate <MB> [--expiry <seconds>]
#       Take the heavy slot for one task. --estimate is the caller's peak-RAM
#       estimate in MB for the job it will run; --expiry is the heartbeat
#       window in seconds the holder must outlive (default 1800, so size it to
#       the job and renew with heartbeat for chained work). Refuses with exit 6
#       and the current holder named when another task holds a live slot.
#       Re-acquiring as the live holder refreshes the hold. A stale or torn
#       record is taken over with a loud note.
#   fm-heavy-slot.sh release <task-id>
#       Drop the slot. Idempotent: releasing an unheld slot succeeds silently.
#       Clears for the recorded holder or when the recorded hold is expired;
#       a different task releasing a live slot is refused with exit 6.
#   fm-heavy-slot.sh heartbeat <task-id>
#       Refresh the heartbeat window for the recorded holder, keeping the
#       recorded estimate and acquiring pid. Refused (exit 6) for a task that
#       is not the live holder; exit 1 when no slot is held.
#   fm-heavy-slot.sh status
#       Print one line for firstmate and the watcher:
#       "held task=<id> pid=<pid> estimate=<MB> age=<s> expires_in=<s> state=live"
#       or "... state=stale", plus a loud stderr warning when stale, or
#       "free" when no slot is held.
#
# Exit codes: 0 ok, 1 no slot held (heartbeat), 2 usage, 6 refused (another
# live holder, or a non-holder acting on a live slot).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

HEAVY_SLOT_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/firstmate"
mkdir -p -- "$HEAVY_SLOT_STATE"
chmod 700 -- "$HEAVY_SLOT_STATE"
SLOT="$HEAVY_SLOT_STATE/heavy-slot"
SLOT_COMMAND_LOCK="$HEAVY_SLOT_STATE/.heavy-slot.lock"
FM_HEAVY_SLOT_DEFAULT_EXPIRY=1800

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

# Same safe-id charset as the supervision lease's task ids (bin/fm-lease-lib.sh
# fm_lease_valid_id): anything that cannot corrupt the state filename.
heavy_slot_valid_id() {
  case "${1:-}" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

heavy_slot_valid_positive_int() {
  case "${1:-}" in
    '' | 0 | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Read the slot record into the FM_HEAVY_SLOT_* variables. Returns 1 when no
# record exists. A malformed field reads as empty so every caller treats the
# record as torn (replaceable), never as a forever-blocked slot.
heavy_slot_read() {
  local line
  FM_HEAVY_SLOT_TASK=
  FM_HEAVY_SLOT_PID=
  FM_HEAVY_SLOT_ESTIMATE=
  FM_HEAVY_SLOT_EPOCH=
  FM_HEAVY_SLOT_EXPIRY=
  [ -e "$SLOT" ] || return 1
  IFS=$'\t' read -r line < "$SLOT" 2>/dev/null || line=
  FM_HEAVY_SLOT_TASK=$(printf '%s' "$line" | cut -f1)
  FM_HEAVY_SLOT_PID=$(printf '%s' "$line" | cut -f2)
  FM_HEAVY_SLOT_ESTIMATE=$(printf '%s' "$line" | cut -f3)
  FM_HEAVY_SLOT_EPOCH=$(printf '%s' "$line" | cut -f4)
  FM_HEAVY_SLOT_EXPIRY=$(printf '%s' "$line" | cut -f5)
  heavy_slot_valid_id "$FM_HEAVY_SLOT_TASK" || FM_HEAVY_SLOT_TASK=
  case "$FM_HEAVY_SLOT_PID" in '' | *[!0-9]*) FM_HEAVY_SLOT_PID= ;; esac
  case "$FM_HEAVY_SLOT_ESTIMATE" in '' | *[!0-9]*) FM_HEAVY_SLOT_ESTIMATE= ;; esac
  case "$FM_HEAVY_SLOT_EPOCH" in '' | *[!0-9]*) FM_HEAVY_SLOT_EPOCH= ;; esac
  case "$FM_HEAVY_SLOT_EXPIRY" in '' | *[!0-9]*) FM_HEAVY_SLOT_EXPIRY= ;; esac
  return 0
}

# A record with an empty field set is torn, not held: no holder identity can be
# read from it, so it must never block an acquire.
heavy_slot_record_intact() {
  [ -n "$FM_HEAVY_SLOT_TASK" ] && [ -n "$FM_HEAVY_SLOT_EPOCH" ] \
    && [ -n "$FM_HEAVY_SLOT_EXPIRY" ] && [ -n "$FM_HEAVY_SLOT_ESTIMATE" ]
}

# 0 iff the recorded heartbeat window has not elapsed. now_epoch is passed in
# by callers that already read the clock once.
heavy_slot_live() {
  local now_epoch=$1 age
  heavy_slot_record_intact || return 1
  age=$(( now_epoch - FM_HEAVY_SLOT_EPOCH ))
  [ "$age" -le "$FM_HEAVY_SLOT_EXPIRY" ]
}

heavy_slot_write() {
  local task=$1 pid=$2 estimate=$3 epoch=$4 expiry=$5 tmp
  tmp=$(mktemp "$HEAVY_SLOT_STATE/.heavy-slot-tmp.XXXXXX")
  printf '%s\t%s\t%s\t%s\t%s\n' "$task" "$pid" "$estimate" "$epoch" "$expiry" > "$tmp"
  mv -f -- "$tmp" "$SLOT"
}

# Round the MB estimate up to the next multiple of 256 MiB for the wrapper's
# MemoryMax, so an estimate of 4000 prints 4096M, never a fractional cap.
heavy_slot_rounded_mb() {
  local mb=$1 rounded
  rounded=$(( (mb + 255) / 256 * 256 ))
  [ "$rounded" -ge 256 ] || rounded=256
  printf '%s\n' "$rounded"
}

# Half the detected CPUs, minimum 1, capped at 8: the parallelism bound the
# wrapper output suggests for the job's own -j flag.
heavy_slot_parallelism_bound() {
  local cpus
  cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
  case "$cpus" in '' | *[!0-9]*) cpus=1 ;; esac
  [ "$cpus" -ge 1 ] || cpus=1
  cpus=$(( cpus / 2 ))
  [ "$cpus" -ge 1 ] || cpus=1
  [ "$cpus" -le 8 ] || cpus=8
  printf '%s\n' "$cpus"
}

heavy_slot_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

heavy_slot_acquire_advice() {
  local task=$1 estimate=$2 expiry=$3 rounded jobs release_cmd
  rounded=$(heavy_slot_rounded_mb "$estimate")
  jobs=$(heavy_slot_parallelism_bound)
  release_cmd=$(heavy_slot_shell_quote "$0")
  printf 'acquired: task=%s estimate=%sMB pid=%s expires_in=%ss\n' \
    "$task" "$estimate" "${BASHPID:-$$}" "$expiry"
  if command -v systemd-run >/dev/null 2>&1; then
    printf 'run the memory-heavy job under the cap wrapper:\n'
    printf '  systemd-run --user --scope -p MemoryMax=%sM -- <command>\n' "$rounded"
  else
    printf 'warning: systemd-run is unavailable, so the memory cap cannot be enforced; still hold the slot and prefer the job own memory limit\n' >&2
    printf 'cap guidance (unenforced without systemd-run): MemoryMax=%sM\n' "$rounded"
  fi
  printf 'keep the job parallelism bounded: no more than -j%s\n' "$jobs"
  printf 'release immediately after the job: %s release %s\n' "$release_cmd" "$task"
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  acquire|release|heartbeat)
    TASK=${1:-}
    shift 2>/dev/null || true
    heavy_slot_valid_id "$TASK" || { usage; exit 2; }
    ;;
  status)
    [ "$#" -eq 0 ] || { usage; exit 2; }
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac

case "$CMD" in
  acquire)
    ESTIMATE=
    EXPIRY=$FM_HEAVY_SLOT_DEFAULT_EXPIRY
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --estimate|--expiry)
          [ "$#" -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
          case "$1" in
            --estimate) ESTIMATE=${2:-} ;;
            --expiry) EXPIRY=${2:-} ;;
          esac
          shift 2
          ;;
        --estimate=*|--expiry=*)
          case "$1" in
            --estimate=*) ESTIMATE=${1#--estimate=} ;;
            --expiry=*) EXPIRY=${1#--expiry=} ;;
          esac
          shift
          ;;
        *)
          echo "error: unknown acquire argument '$1'" >&2
          usage
          exit 2
          ;;
      esac
    done
    heavy_slot_valid_positive_int "$ESTIMATE" \
      || { echo "error: --estimate requires a positive integer MB value (got '${ESTIMATE:-none}')" >&2; exit 2; }
    heavy_slot_valid_positive_int "$EXPIRY" \
      || { echo "error: --expiry requires a positive integer seconds value (got '${EXPIRY:-none}')" >&2; exit 2; }
    fm_lock_acquire_wait "$SLOT_COMMAND_LOCK"
    trap 'fm_lock_release "$SLOT_COMMAND_LOCK"' EXIT
    fm_epoch_seconds_to NOW
    if heavy_slot_read && heavy_slot_record_intact && heavy_slot_live "$NOW"; then
      if [ "$FM_HEAVY_SLOT_TASK" != "$TASK" ]; then
        echo "error: heavy slot held by task '$FM_HEAVY_SLOT_TASK' (pid ${FM_HEAVY_SLOT_PID:-unknown}, estimate ${FM_HEAVY_SLOT_ESTIMATE}MB, held $(( NOW - FM_HEAVY_SLOT_EPOCH ))s, expires in $(( FM_HEAVY_SLOT_EXPIRY - (NOW - FM_HEAVY_SLOT_EPOCH) ))s); declare a wait and retry acquire later, never run the job uncapped" >&2
        exit 6
      fi
      echo "note: refreshing the heavy slot already held by task '$TASK'" >&2
    elif heavy_slot_read; then
      if heavy_slot_record_intact; then
        echo "note: taking over the stale heavy slot held by task '$FM_HEAVY_SLOT_TASK' (heartbeat expired $(( NOW - FM_HEAVY_SLOT_EPOCH - FM_HEAVY_SLOT_EXPIRY ))s ago)" >&2
      else
        echo "note: replacing a torn heavy-slot record" >&2
      fi
    fi
    heavy_slot_write "$TASK" "${BASHPID:-$$}" "$ESTIMATE" "$NOW" "$EXPIRY"
    heavy_slot_acquire_advice "$TASK" "$ESTIMATE" "$EXPIRY"
    ;;
  release)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$SLOT_COMMAND_LOCK"
    trap 'fm_lock_release "$SLOT_COMMAND_LOCK"' EXIT
    fm_epoch_seconds_to NOW
    if ! heavy_slot_read; then
      printf 'free: no heavy slot was held\n'
      exit 0
    fi
    if ! heavy_slot_record_intact; then
      echo "note: clearing a torn heavy-slot record" >&2
      rm -f -- "$SLOT"
      printf 'released: cleared torn record\n'
      exit 0
    fi
    if [ "$FM_HEAVY_SLOT_TASK" != "$TASK" ] && heavy_slot_live "$NOW"; then
      echo "error: release refused - the live heavy slot is held by task '$FM_HEAVY_SLOT_TASK' (pid ${FM_HEAVY_SLOT_PID:-unknown}), not '$TASK'; a non-holder never clears a live slot (expired slots clear for anyone)" >&2
      exit 6
    fi
    if [ "$FM_HEAVY_SLOT_TASK" != "$TASK" ]; then
      echo "note: clearing the expired heavy slot held by task '$FM_HEAVY_SLOT_TASK'" >&2
    fi
    rm -f -- "$SLOT"
    printf 'released: task=%s\n' "$TASK"
    ;;
  heartbeat)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$SLOT_COMMAND_LOCK"
    trap 'fm_lock_release "$SLOT_COMMAND_LOCK"' EXIT
    fm_epoch_seconds_to NOW
    heavy_slot_read || { echo "error: heartbeat refused - no heavy slot is held" >&2; exit 1; }
    heavy_slot_record_intact \
      || { echo "error: heartbeat refused - the heavy-slot record is torn; acquire again" >&2; exit 1; }
    if [ "$FM_HEAVY_SLOT_TASK" != "$TASK" ]; then
      echo "error: heartbeat refused - the heavy slot is held by task '$FM_HEAVY_SLOT_TASK', not '$TASK'" >&2
      exit 6
    fi
    heavy_slot_write "$FM_HEAVY_SLOT_TASK" "$FM_HEAVY_SLOT_PID" "$FM_HEAVY_SLOT_ESTIMATE" "$NOW" "$FM_HEAVY_SLOT_EXPIRY"
    printf 'heartbeat: task=%s estimate=%sMB expires_in=%ss\n' \
      "$FM_HEAVY_SLOT_TASK" "$FM_HEAVY_SLOT_ESTIMATE" "$FM_HEAVY_SLOT_EXPIRY"
    ;;
  status)
    fm_lock_acquire_wait "$SLOT_COMMAND_LOCK"
    trap 'fm_lock_release "$SLOT_COMMAND_LOCK"' EXIT
    fm_epoch_seconds_to NOW
    if ! heavy_slot_read || ! heavy_slot_record_intact; then
      if heavy_slot_read; then
        echo "warning: heavy-slot record is torn (unreadable holder); acquire will replace it" >&2
      fi
      printf 'free\n'
      exit 0
    fi
    AGE=$(( NOW - FM_HEAVY_SLOT_EPOCH ))
    REMAINING=$(( FM_HEAVY_SLOT_EXPIRY - AGE ))
    STATE_WORD=live
    if ! heavy_slot_live "$NOW"; then
      STATE_WORD=stale
      echo "warning: heavy slot holder '$FM_HEAVY_SLOT_TASK' is stale - heartbeat expired $(( AGE - FM_HEAVY_SLOT_EXPIRY ))s ago (age ${AGE}s over window ${FM_HEAVY_SLOT_EXPIRY}s); acquire will take it over" >&2
    fi
    printf 'held task=%s pid=%s estimate=%sMB age=%ss expires_in=%ss state=%s\n' \
      "$FM_HEAVY_SLOT_TASK" "${FM_HEAVY_SLOT_PID:-unknown}" "$FM_HEAVY_SLOT_ESTIMATE" "$AGE" "$REMAINING" "$STATE_WORD"
    ;;
esac
