#!/usr/bin/env bash
# Behavior regressions for the automatic lint entrypoint resource binding.
# Drives the same plain shell command as configured automatic Lint against
# bounded fixtures, using the real heavy-slot owner and real systemd scopes.
# The actual daemon-owned pipeline result is recorded separately at shipping.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LINT="$ROOT/bin/fm-lint.sh"
BINDING_TMP=$(fm_test_tmproot fm-lint-binding)

binding_fixture() {  # <name>
  BINDING_CASE="$BINDING_TMP/$1"
  BINDING_REPO="$BINDING_CASE/repo"
  BINDING_HOME="$BINDING_CASE/declared home"
  BINDING_CONFIG="$BINDING_CASE/config"
  BINDING_STATE="$BINDING_CASE/state"
  BINDING_TRACE="$BINDING_CASE/trace"
  BINDING_FAKEBIN="$BINDING_CASE/fakebin"
  mkdir -p "$BINDING_REPO/bin" "$BINDING_REPO/tests" "$BINDING_HOME" \
    "$BINDING_CONFIG/firstmate" "$BINDING_STATE" "$BINDING_TRACE" "$BINDING_FAKEBIN"
  git -C "$BINDING_REPO" init -q || fail 'cannot isolate lint fixture Git context'
  mkdir -p "$BINDING_HOME/bin"
  ln -s "$ROOT/bin/fm-timeout-lib.sh" "$BINDING_HOME/bin/fm-timeout-lib.sh"
  cat > "$BINDING_HOME/bin/fm-heavy-slot.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = release ] && [ -f "$BINDING_TRACE/scopes" ]; then
  while IFS= read -r group; do
    if [ -e "/sys/fs/cgroup$group/cgroup.events" ]; then
      cat "/sys/fs/cgroup$group/cgroup.events" >> "$BINDING_TRACE/release-events"
    else
      printf 'populated 0\n' >> "$BINDING_TRACE/release-events"
    fi
  done < "$BINDING_TRACE/scopes"
fi
exec "$BINDING_OWNER_HELPER" "$@"
SH
  chmod +x "$BINDING_HOME/bin/fm-heavy-slot.sh"
  cp "$LINT" "$ROOT/bin/fm-lint-resource-lib.sh" "$ROOT/bin/fm-timeout-lib.sh" "$BINDING_REPO/bin/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDING_REPO/bin/fm-lint-workflows.sh"
  chmod +x "$BINDING_REPO/bin/fm-lint-workflows.sh"
  printf '#!/usr/bin/env bash\nprintf "ok\\n"\n' > "$BINDING_REPO/tests/root.test.sh"
  perl -MJSON::PP -e 'print encode_json({home => $ARGV[0], jobs => 1, estimate_mib => 256})' \
    "$BINDING_HOME" > "$BINDING_CONFIG/firstmate/lint-resource-binding.json"
  chmod 600 "$BINDING_CONFIG/firstmate/lint-resource-binding.json"
  cat > "$BINDING_FAKEBIN/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'ShellCheck\nversion: 0.11.0\n'
  exit 0
fi
mkdir "$BINDING_TRACE/inflight" || { printf 'overlap\n' >> "$BINDING_TRACE/overlap"; exit 90; }
trap 'rmdir "$BINDING_TRACE/inflight"' EXIT
group=$(awk -F: '$1 == 0 {print $3}' /proc/self/cgroup 2>/dev/null)
printf '%s\n' "$group" >> "$BINDING_TRACE/scopes"
cap=$(cat "/sys/fs/cgroup$group/memory.max" 2>/dev/null || printf unavailable)
held=$("$BINDING_HOME/bin/fm-heavy-slot.sh" status)
printf 'pid=%s cap=%s %s\n' "$$" "$cap" "$held" >> "$BINDING_TRACE/children"
if [ "${BINDING_STRAGGLER:-0}" = 1 ]; then
  perl -MPOSIX=setpgid -e '
    pipe(my $read, my $write) or die $!;
    my $pid = fork;
    die $! unless defined $pid;
    if (!$pid) {
      close $read;
      setpgid(0, 0) == 0 or die $!;
      $SIG{TERM} = "IGNORE";
      close STDIN; close STDOUT; close STDERR;
      open my $fh, ">>", "$ENV{BINDING_TRACE}/stragglers" or die $!;
      print $fh "$$\n";
      close $fh;
      print $write "ready\n";
      close $write;
      sleep 60;
      exit 0;
    }
    close $write;
    <$read> or die "straggler did not start";
  '
fi
cat "/sys/fs/cgroup$group/cgroup.procs" >> "$BINDING_TRACE/scope-pids" 2>/dev/null || true
root_group=$(ps -o pgid= -p "$$" | tr -d ' ')
watchdog_pid=$PPID
while [ "$watchdog_pid" -gt 1 ]; do
  watchdog_group=$(ps -o pgid= -p "$watchdog_pid" | tr -d ' ')
  [ "$watchdog_group" = "$root_group" ] || break
  printf '%s\n' "$watchdog_pid" >> "$BINDING_TRACE/root-group-ancestors"
  watchdog_pid=$(ps -o ppid= -p "$watchdog_pid" | tr -d ' ')
done
printf '%s %s\n' "$$" "$root_group" >> "$BINDING_TRACE/groups"
printf '%s %s\n' "$watchdog_pid" "$watchdog_group" >> "$BINDING_TRACE/groups"
touch "$BINDING_TRACE/ready"
if [ "${BINDING_BLOCK:-0}" = 1 ]; then sleep 60; else sleep 0.1; fi
if [ "${BINDING_LITERAL_ROOT:-0}" = 1 ]; then
  for root in "$@"; do :; done
  printf '%s\n' "$root" >> "$BINDING_TRACE/requested-roots"
  case "$root" in
    'tests/${FLAVOR}.sh') printf '%s: fixture finding\n' "$root"; exit 1 ;;
    *) exit 0 ;;
  esac
fi
exit "${BINDING_EXIT:-0}"
SH
  chmod +x "$BINDING_FAKEBIN/shellcheck"
}

binding_timing_intermediary() {
  mv "$BINDING_FAKEBIN/shellcheck" "$BINDING_FAKEBIN/shellcheck-payload"
  cat > "$BINDING_FAKEBIN/shellcheck" <<'SH'
#!/usr/bin/env bash
payload="$(dirname "$0")/shellcheck-payload"
if [ "${1:-}" = --version ]; then exec "$payload" "$@"; fi
printf '%s\n' "$$" >> "$BINDING_TRACE/intermediaries"
"$payload" "$@" &
wait "$!"
SH
  chmod +x "$BINDING_FAKEBIN/shellcheck"
}

binding_slot() {
  XDG_STATE_HOME="$BINDING_STATE" BINDING_TRACE="$BINDING_TRACE" \
    BINDING_OWNER_HELPER="$ROOT/bin/fm-heavy-slot.sh" "$BINDING_HOME/bin/fm-heavy-slot.sh" "$@"
}

# Exercise the plain command selected by automatic Lint through its real
# public entrypoint and shell boundary, without a resource flag or marker.
# The daemon end-to-end result belongs to the actual pipeline's evidence.
binding_lint() {
  (
    cd "$BINDING_REPO" || exit 1
    env -u FM_LINT_RESOURCE_TASK XDG_CONFIG_HOME="$BINDING_CONFIG" XDG_STATE_HOME="$BINDING_STATE" \
      BINDING_TRACE="$BINDING_TRACE" BINDING_HOME="$BINDING_HOME" \
      BINDING_OWNER_HELPER="$ROOT/bin/fm-heavy-slot.sh" \
      BINDING_REAL_SYSTEMD_RUN="$(command -v systemd-run)" \
      BINDING_BLOCK="${BINDING_BLOCK:-0}" BINDING_EXIT="${BINDING_EXIT:-0}" \
      BINDING_LITERAL_ROOT="${BINDING_LITERAL_ROOT:-0}" \
      BINDING_STRAGGLER="${BINDING_STRAGGLER:-0}" \
      FM_LINT_REQUIRE_BOUNDS="${BINDING_BOUNDS:-0}" FM_LINT_ROOT_GRACE=10 \
      FM_LINT_JOBS=2 FM_LINT_TELEMETRY="$BINDING_TRACE/telemetry.tsv" \
      PATH="$BINDING_FAKEBIN:$PATH" sh -c 'bin/fm-lint.sh "$@"' sh "$@"
  )
}

binding_assert_scope_stopped() {
  local pid group
  [ "$(binding_slot status)" = free ] || fail 'lint did not release promptly after scope cleanup'
  [ -s "$BINDING_TRACE/release-events" ] || fail 'release did not observe its analysis scope'
  if grep -q '^populated 1$' "$BINDING_TRACE/release-events"; then
    fail 'capacity was released while the analysis scope still had processes'
  fi
  while IFS= read -r group; do
    case "$group" in */lint-*.scope) ;; *) fail 'analysis did not enter its own lint scope' ;; esac
    if [ -e "/sys/fs/cgroup$group/cgroup.events" ]; then
      grep -q '^populated 0$' "/sys/fs/cgroup$group/cgroup.events" || fail 'analysis scope remains populated'
    fi
  done < "$BINDING_TRACE/scopes"
  while IFS= read -r pid; do
    if kill -0 "$pid" 2>/dev/null; then
      case "$(ps -o stat= -p "$pid" | tr -d ' ')" in
        Z*|'') ;; *) fail "analysis scope left process $pid executing" ;;
      esac
    fi
  done < "$BINDING_TRACE/scope-pids"
  [ -s "$BINDING_TRACE/stragglers" ] || fail 'scope cleanup checked no separately grouped straggler'
  while IFS= read -r pid; do
    if kill -0 "$pid" 2>/dev/null; then
      case "$(ps -o stat= -p "$pid" | tr -d ' ')" in
        Z*|'') ;; *) fail 'scope cleanup left a TERM-resistant straggler executing' ;;
      esac
    fi
  done < "$BINDING_TRACE/stragglers"
  awk 'NR % 2 {group=$2; next} $2 == group || $1 != $2 {bad=1} END {exit (bad || NR == 0 || NR % 2)}' "$BINDING_TRACE/groups" \
    || fail 'required-bounds fixture did not exercise distinct process groups'
  if [ -s "$BINDING_TRACE/intermediaries" ]; then
    [ -s "$BINDING_TRACE/root-group-ancestors" ] || fail 'timing fixture observed no ancestor in the analysis group'
    awk 'NR == FNR {ancestors[$1]=1; next} !($1 in ancestors) {bad=1} END {exit bad}' \
      "$BINDING_TRACE/root-group-ancestors" "$BINDING_TRACE/intermediaries" \
      || fail 'timing intermediary was not observed inside the analysis group'
    awk 'NR == FNR {intermediaries[$1]=1; next} FNR % 2 == 0 && ($1 in intermediaries) {bad=1} END {exit bad}' \
      "$BINDING_TRACE/intermediaries" "$BINDING_TRACE/groups" \
      || fail 'cleanup assertion mistook a timing intermediary for the watchdog'
  fi
}

test_lint_binding_validation_and_portable_absence() {
  local out rc
  binding_fixture validation
  printf '{"home":"/missing","jobs":2,"estimate_mib":256}\n' > "$BINDING_CONFIG/firstmate/lint-resource-binding.json"
  rc=0; out=$(binding_lint 2>&1) || rc=$?
  expect_code 2 "$rc" 'a binding cannot request two lint jobs'
  assert_contains "$out" 'jobs must be the integer 1' 'invalid jobs must name the binding problem'
  [ ! -e "$BINDING_TRACE/children" ] || fail 'invalid binding ran an analysis child'
  printf 'invalid JSON\n' > "$BINDING_CONFIG/firstmate/lint-resource-binding.json"
  rc=0; out=$(binding_lint 2>&1) || rc=$?
  expect_code 2 "$rc" 'malformed binding must fail closed'
  [ ! -e "$BINDING_TRACE/children" ] || fail 'malformed binding ran an analysis child'
  binding_fixture permissions
  chmod 644 "$BINDING_CONFIG/firstmate/lint-resource-binding.json"
  rc=0; out=$(binding_lint 2>&1) || rc=$?
  expect_code 2 "$rc" 'the binding must remain user-private'
  assert_contains "$out" 'private user-owned regular file' 'record permissions must be diagnosed'
  binding_fixture missing-home
  rm "$BINDING_HOME/bin/fm-heavy-slot.sh"
  rc=0; out=$(binding_lint 2>&1) || rc=$?
  expect_code 2 "$rc" 'the declared helper must exist without guessing another home'
  assert_contains "$out" 'declared heavy-slot helper is unavailable' 'missing owner must be named'
  binding_fixture portable
  rm "$BINDING_CONFIG/firstmate/lint-resource-binding.json"
  # No host dependency may leak into an ordinary unconfigured lint caller.
  printf '#!/usr/bin/env bash\nexit 99\n' > "$BINDING_FAKEBIN/systemd-run"
  chmod +x "$BINDING_FAKEBIN/systemd-run"
  # Two workers are deliberately requested; use distinct trace dirs to keep
  # this baseline from imposing the single-job assertion in the bound cases.
  rm "$BINDING_FAKEBIN/shellcheck"
  cat > "$BINDING_FAKEBIN/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf 'version: 0.11.0\n'; fi
exit 0
SH
  chmod +x "$BINDING_FAKEBIN/shellcheck"
  rc=0; out=$(binding_lint 2>&1) || rc=$?
  expect_code 0 "$rc" 'unconfigured callers must retain lint without a systemd cap'
  assert_contains "$(cat "$BINDING_TRACE/telemetry.tsv")" $'jobs\t2' 'ordinary caller jobs changed'
  pass 'lint resource binding: malformed/private/home validation and portable absence'
}

test_lint_binding_real_scope() {
  local out rc held child_pid parent_pid i task owner_pid started
  fm_live_gate default-on FM_LIVE_LINT_RESOURCE systemd-run systemctl
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    if [ "${FM_LIVE_LINT_RESOURCE:-${FM_LIVE:-0}}" = 1 ]; then fail 'real lint resource proof requires systemd-run and an available user manager'; fi
    pass 'SKIP (systemd user manager unavailable): real lint resource scope'
    return
  fi
  binding_fixture contention
  binding_slot acquire existing-holder --estimate 256 >/dev/null
  rc=0
  out=$(cd "$BINDING_REPO" && XDG_CONFIG_HOME="$BINDING_CONFIG" XDG_STATE_HOME="$BINDING_STATE" \
    bash bin/fm-lint.sh --list-files 2>&1) || rc=$?
  expect_code 0 "$rc" 'query-only lint must not contend for a heavy slot'
  assert_contains "$out" 'tests/root.test.sh' 'query-only lint must return its real inventory'
  [ "$(binding_slot status)" != free ] || fail 'query-only lint released another holder'
  rc=0; out=$(binding_lint 2>&1) || rc=$?
  expect_code 6 "$rc" 'occupied canonical slot must refuse plain automatic lint'
  assert_contains "$out" "held by task 'existing-holder'" 'contention must name the holder'
  [ ! -e "$BINDING_TRACE/children" ] || fail 'contending lint ran a child'
  held=$(binding_slot status)
  assert_contains "$held" 'held task=existing-holder' 'a refused lint must not release another holder'
  binding_slot release existing-holder >/dev/null
  binding_fixture success
  BINDING_BOUNDS=1
  BINDING_STRAGGLER=1
  started=$SECONDS
  rc=0; out=$(binding_lint 2>&1) || rc=$?
  expect_code 0 "$rc" 'plain automatic entrypoint must pass under the real cap'
  assert_contains "$out" 'bound task=lint-' 'bound entrypoint must report the verified holder'
  assert_contains "$out" 'jobs=1 MemoryMax=256M' 'bound entrypoint must enforce one job and the owner cap'
  assert_contains "$(cat "$BINDING_TRACE/telemetry.tsv")" $'jobs\t1' 'actual lint telemetry must report one job'
  [ ! -e "$BINDING_TRACE/overlap" ] || fail 'bound lint ran overlapping analysis children'
  while IFS= read -r held; do
    assert_contains "$held" 'cap=268435456 held task=lint-' 'analysis child must see the kernel cap and its live slot'
  done < "$BINDING_TRACE/children"
  [ -s "$BINDING_TRACE/children" ] || fail 'real cap proof checked no analysis children'
  printf 'resource proof: %s\n' "$(grep '^fm-lint.sh: bound ' <<< "$out")"
  printf 'resource proof: %s\n' "$(awk -F '\t' '$1 == "jobs" || $1 == "root_count" {print $1 "=" $2}' "$BINDING_TRACE/telemetry.tsv" | tr '\n' ' ')"
  printf 'resource proof: %s\n' "$(head -1 "$BINDING_TRACE/children")"
  awk -F '\t' '$1 == "root_count" {count=$2} END {exit !(count > 1)}' "$BINDING_TRACE/telemetry.tsv" \
    || fail 'single-job proof must exercise multiple roots'
  binding_assert_scope_stopped
  [ "$((SECONDS - started))" -lt 20 ] || fail 'successful lint scope release was not prompt'
  binding_fixture success-timed
  binding_timing_intermediary
  started=$SECONDS
  rc=0; out=$(binding_lint 2>&1) || rc=$?
  expect_code 0 "$rc" 'scope cleanup must pass with a timing intermediary'
  binding_assert_scope_stopped
  [ "$((SECONDS - started))" -lt 20 ] || fail 'timed successful lint scope release was not prompt'
  binding_fixture failure
  binding_timing_intermediary
  BINDING_EXIT=7
  started=$SECONDS
  rc=0; out=$(binding_lint 2>&1) || rc=$?
  unset BINDING_EXIT
  expect_code 7 "$rc" 'a scoped analysis exit must propagate through the plain entrypoint'
  binding_assert_scope_stopped
  [ "$((SECONDS - started))" -lt 20 ] || fail 'failed lint scope release was not prompt'
  unset BINDING_BOUNDS BINDING_STRAGGLER
  binding_fixture unavailable-cap
  printf '#!/usr/bin/env bash\nexit 99\n' > "$BINDING_FAKEBIN/systemd-run"
  chmod +x "$BINDING_FAKEBIN/systemd-run"
  rc=0; out=$(binding_lint 2>&1) || rc=$?
  expect_code 99 "$rc" 'a scope-launch failure must propagate without an uncapped retry'
  [ ! -e "$BINDING_TRACE/children" ] || fail 'scope-launch failure ran lint'
  [ "$(binding_slot status)" = free ] || fail 'scope-launch failure leaked the slot'
  binding_fixture forged-cap
  cat > "$BINDING_FAKEBIN/systemd-run" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"
SH
  chmod +x "$BINDING_FAKEBIN/systemd-run"
  rc=0; out=$(binding_lint 2>&1) || rc=$?
  expect_code 2 "$rc" 'an unscoped marker must never stand in for a kernel cap'
  assert_contains "$out" 'resident-memory cap mismatch' 'unenforced wrapper must be diagnosed'
  [ ! -e "$BINDING_TRACE/children" ] || fail 'an unenforced wrapper ran lint'
  [ "$(binding_slot status)" = free ] || fail 'cap refusal leaked the slot'
  binding_fixture removed-record
  cat > "$BINDING_FAKEBIN/systemd-run" <<'SH'
#!/usr/bin/env bash
rm "$XDG_CONFIG_HOME/firstmate/lint-resource-binding.json"
exec "$BINDING_REAL_SYSTEMD_RUN" "$@"
SH
  chmod +x "$BINDING_FAKEBIN/systemd-run"
  rc=0; out=$(binding_lint 2>&1) || rc=$?
  expect_code 2 "$rc" 'a binding removed during scoped launch must fail closed'
  assert_contains "$out" 'invalid resource binding' 'removed binding must be diagnosed'
  [ ! -e "$BINDING_TRACE/children" ] || fail 'scoped re-entry silently lost its binding'
  [ "$(binding_slot status)" = free ] || fail 'removed binding leaked the slot'
  binding_fixture literal-argv
  printf '#!/usr/bin/env bash\nif then\n' > "$BINDING_REPO/tests/"'${FLAVOR}.sh'
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDING_REPO/tests/clean.sh"
  rc=0
  out=$(FLAVOR=clean BINDING_LITERAL_ROOT=1 binding_lint \
    --telemetry "$BINDING_TRACE/"'${FLAVOR}.tsv' 'tests/${FLAVOR}.sh' 2>&1) || rc=$?
  expect_code 1 "$rc" 'the literal defective root must not expand to the clean alternative'
  [ "$(cat "$BINDING_TRACE/requested-roots")" = 'tests/${FLAVOR}.sh' ] || fail 'scope launch rewrote the requested root'
  [ -f "$BINDING_TRACE/"'${FLAVOR}.tsv' ] || fail 'scope launch rewrote the telemetry path'
  [ ! -e "$BINDING_TRACE/clean.tsv" ] || fail 'scope launch wrote telemetry to the expanded alternative'
  [ "$(binding_slot status)" = free ] || fail 'literal argument lint leaked the slot'
  binding_fixture 'paths-${FLAVOR}'
  ln -s "$(command -v bash)" "$BINDING_FAKEBIN/bash"
  rc=0; out=$(FLAVOR=clean binding_lint 2>&1) || rc=$?
  expect_code 0 "$rc" 'scope launch must preserve literal SELF and executable paths'
  [ -s "$BINDING_TRACE/children" ] || fail 'literal executable and SELF paths did not reach analysis'
  [ "$(binding_slot status)" = free ] || fail 'literal executable path lint leaked the slot'
  binding_fixture signal
  binding_timing_intermediary
  BINDING_BOUNDS=1
  BINDING_STRAGGLER=1
  BINDING_BLOCK=1 binding_lint > "$BINDING_TRACE/output" 2>&1 &
  parent_pid=$!
  for ((i=0; i<200; i++)); do [ ! -e "$BINDING_TRACE/ready" ] || break; sleep 0.1; done
  [ -e "$BINDING_TRACE/ready" ] || { kill "$parent_pid" 2>/dev/null || true; fail 'signal fixture never entered its bound analysis'; }
  child_pid=$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$BINDING_TRACE/children" | head -1)
  # Signal the actual outer lint owner, rather than the fixture shell.
  held=$(binding_slot status)
  task=$(printf '%s\n' "$held" | sed -n 's/^held task=\([^ ]*\).*/\1/p')
  owner_pid=${task#lint-}; owner_pid=${owner_pid%%-*}
  started=$SECONDS
  kill -TERM "$owner_pid"
  rc=0; wait "$parent_pid" || rc=$?
  expect_code 143 "$rc" 'interruption must propagate its signal exit'
  binding_assert_scope_stopped
  [ "$((SECONDS - started))" -lt 20 ] || fail 'interrupted lint scope release was not prompt'
  if kill -0 "$child_pid" 2>/dev/null; then
    [ "$(ps -o stat= -p "$child_pid" | tr -d ' ')" = Z ] || fail 'interrupted lint left an analysis child executing'
  fi
  binding_fixture deadline
  binding_timing_intermediary
  # Compress only the fixture's whole-job watchdog, retaining the real owner
  # and real process-group runner. This proves the slot is released on a
  # bounded hung child without waiting for the production lease to expire.
  cat > "$BINDING_REPO/bin/fm-timeout-lib.sh" <<'SH'
#!/usr/bin/env bash
fm_exec_timed() {
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$BINDING_HOME/bin/fm-timeout-lib.sh"
  if [ "$1" = 1770 ]; then
    printf '%s %s\n' "$1" "$2" > "$BINDING_TRACE/job-bound"
    shift 2
    fm_exec_timed 8 1 "$@"
  else
    fm_exec_timed "$@"
  fi
}
SH
  BINDING_BLOCK=1
  started=$SECONDS
  rc=0; out=$(binding_lint 2>&1) || rc=$?
  unset BINDING_BLOCK
  expect_code 124 "$rc" 'whole-job deadline must propagate the timed-out exit'
  [ "$(cat "$BINDING_TRACE/job-bound")" = '1770 5' ] || fail 'whole-job deadline no longer precedes slot expiry'
  binding_assert_scope_stopped
  [ "$((SECONDS - started))" -lt 25 ] || fail 'whole-job deadline scope release was not prompt'
  [ -s "$BINDING_TRACE/children" ] || fail 'deadline fixture timed out before entering analysis'
  child_pid=$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$BINDING_TRACE/children" | head -1)
  if kill -0 "$child_pid" 2>/dev/null; then
    [ "$(ps -o stat= -p "$child_pid" | tr -d ' ')" = Z ] || fail 'whole-job deadline left an analysis child executing'
  fi
  unset BINDING_BOUNDS BINDING_STRAGGLER
  pass 'lint resource binding: real cap, one job, contention, ownership, exits, signal and deadline release'
}


