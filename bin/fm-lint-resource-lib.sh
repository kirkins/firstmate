#!/usr/bin/env bash
# fm-lint-resource-lib.sh - private resource binding for the lint entrypoint.
# Sourced by fm-lint.sh, whose header owns the operator opt-in and schema.
# The declared home's existing heavy-slot helper remains the admission and
# cap-policy owner; the cap is read from its printed wrapper, never evaluated.

fm_lint_resource_refuse() {
  printf 'fm-lint.sh: %s; refusing uncapped lint.\n' "$*" >&2
  exit 2
}

fm_lint_resource_load() {  # <binding-file>; prints home and estimate on two lines
  # shellcheck disable=SC2016 # Perl expressions must reach the interpreter unchanged.
  "$PERL_BIN" -MJSON::PP -e '
    my $path = shift;
    my @st = lstat $path;
    die "binding must be a private user-owned regular file\n"
      unless @st && -f _ && $st[4] == $< && ($st[2] & 077) == 0;
    open my $fh, "<", $path or die "read binding: $!\n";
    local $/;
    my $data = decode_json(<$fh>);
    die "binding requires exactly home, jobs, estimate_mib\n"
      unless ref($data) eq "HASH"
        && join(",", sort keys %$data) eq "estimate_mib,home,jobs";
    my $home = $data->{home};
    die "binding home must be an absolute path without control characters\n"
      unless defined($home) && !ref($home) && $home =~ m{\A/}
        && $home !~ /[\x00-\x1f\x7f]/;
    die "binding jobs must be the integer 1\n"
      unless encode_json($data->{jobs}) eq "1";
    my $estimate = encode_json($data->{estimate_mib});
    die "binding estimate_mib must be a positive integer of at most nine digits\n"
      unless $estimate =~ /\A[1-9][0-9]{0,8}\z/;
    print "$home\n$estimate\n";
  ' -- "$1"
}

fm_lint_resource_cap() {  # <acquire-output>; prints the cap from the owner
  printf '%s\n' "$1" | sed -n 's/^  systemd-run --user --scope -p MemoryMax=\([1-9][0-9]*\)M -- <command>$/\1/p'
}

# shellcheck disable=SC2329 # EXIT and signal traps own this cleanup.
fm_lint_resource_cleanup() {
  local state
  trap '' HUP INT TERM
  if [ -n "${FM_LINT_RESOURCE_RUN_PID:-}" ]; then
    kill -TERM "$FM_LINT_RESOURCE_RUN_PID" 2>/dev/null || true
    wait "$FM_LINT_RESOURCE_RUN_PID" 2>/dev/null || true
    FM_LINT_RESOURCE_RUN_PID=
  fi
  if ! systemctl --user stop "$FM_LINT_RESOURCE_OWNER.scope" >&2; then
    state=$(systemctl --user show "$FM_LINT_RESOURCE_OWNER.scope" -p LoadState --value) || state=
    if [ "$state" != not-found ]; then
      printf 'fm-lint.sh: cannot confirm owned scope stopped; retaining heavy slot %s.\n' "$FM_LINT_RESOURCE_OWNER" >&2
      return 1
    fi
  fi
  "$FM_LINT_RESOURCE_HELPER" release "$FM_LINT_RESOURCE_OWNER" >&2
}

fm_lint_resource_enter() {  # <binding-file> <original lint arguments...>
  local file=$1 values home estimate canonical task advice cap rc=0 held group actual owner_pid
  shift
  values=$(fm_lint_resource_load "$file") || fm_lint_resource_refuse "invalid resource binding $file"
  home=${values%%$'\n'*}
  estimate=${values#*$'\n'}
  canonical=$(cd "$home" 2>/dev/null && pwd -P) || fm_lint_resource_refuse "declared home is unavailable: $home"
  [ "$canonical" = "$home" ] || fm_lint_resource_refuse "binding home must name its canonical path: $canonical"
  FM_LINT_RESOURCE_HELPER="$home/bin/fm-heavy-slot.sh"
  [ -x "$FM_LINT_RESOURCE_HELPER" ] || fm_lint_resource_refuse "declared heavy-slot helper is unavailable: $FM_LINT_RESOURCE_HELPER"

  if [ -n "${FM_LINT_RESOURCE_TASK:-}" ]; then
    # Only the scoped re-entry may consume the hold. A forged/inherited marker
    # outside that real kernel cap is a refusal, never a skip of enforcement.
    task=$FM_LINT_RESOURCE_TASK
    case "$task" in
      *[!A-Za-z0-9._-]*) fm_lint_resource_refuse 'invalid scoped lint identity' ;;
    esac
    held=$("$FM_LINT_RESOURCE_HELPER" status) || fm_lint_resource_refuse 'cannot verify heavy-slot ownership'
    case "$held" in
      "held task=$task "*" state=live") ;;
      *) fm_lint_resource_refuse "scoped lint does not own a live heavy slot: $held" ;;
    esac
    # Re-acquire as the verified holder so the existing owner supplies the
    # estimate's wrapper without replicating its rounding policy here.
    advice=$("$FM_LINT_RESOURCE_HELPER" acquire "$task" --estimate "$estimate" --expiry 1800) || exit $?
    cap=$(fm_lint_resource_cap "$advice")
    case "$cap" in ''|*[!0-9]*) fm_lint_resource_refuse 'heavy-slot owner did not supply an enforceable cap wrapper' ;; esac
    group=$(awk -F: '$1 == 0 {print $3}' /proc/self/cgroup 2>/dev/null)
    case "$group" in /*) ;; *) fm_lint_resource_refuse 'cannot resolve the scoped cgroup' ;; esac
    actual=$(cat "/sys/fs/cgroup$group/memory.max" 2>/dev/null) || fm_lint_resource_refuse 'cannot read the resident-memory cap'
    [ "$actual" = "$((cap * 1024 * 1024))" ] || fm_lint_resource_refuse "resident-memory cap mismatch: got $actual, expected ${cap}MiB"
    # shellcheck disable=SC2034 # The sourced lint caller consumes this value.
    JOBS=1
    unset FM_LINT_RESOURCE_TASK
    printf 'fm-lint.sh: bound task=%s jobs=1 MemoryMax=%sM memory.max=%s cgroup=%s helper=%s\n' "$task" "$cap" "$actual" "$group" "$FM_LINT_RESOURCE_HELPER" >&2
    return 0
  fi

  declare -F fm_exec_timed >/dev/null 2>&1 || fm_lint_resource_refuse 'fm-timeout-lib.sh is unavailable'
  command -v systemd-run >/dev/null 2>&1 || fm_lint_resource_refuse 'systemd-run is unavailable'
  command -v systemctl >/dev/null 2>&1 || fm_lint_resource_refuse 'systemctl is unavailable'
  task="lint-${BASHPID:-$$}-$(date +%s)"
  advice=$("$FM_LINT_RESOURCE_HELPER" acquire "$task" --estimate "$estimate" --expiry 1800) || exit $?
  FM_LINT_RESOURCE_OWNER=$task
  FM_LINT_RESOURCE_RUN_PID=
  trap fm_lint_resource_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  printf '%s\n' "$advice" >&2
  cap=$(fm_lint_resource_cap "$advice")
  case "$cap" in ''|*[!0-9]*) fm_lint_resource_refuse 'heavy-slot owner did not supply an enforceable cap wrapper' ;; esac
  owner_pid=${BASHPID:-$$}
  (
    # shellcheck disable=SC2034 # The sourced fm_exec_timed reads this owner.
    FM_EXEC_TIMED_OWNER_PID=$owner_pid
    fm_exec_timed 1770 5 systemd-run --user --scope --expand-environment=no -p "MemoryMax=${cap}M" \
      --unit="$task.scope" -p TimeoutStopSec=5s -- \
      env FM_LINT_RESOURCE_TASK="$task" "${BASH:-bash}" "$SELF" "$@"
  ) &
  FM_LINT_RESOURCE_RUN_PID=$!
  wait "$FM_LINT_RESOURCE_RUN_PID" || rc=$?
  FM_LINT_RESOURCE_RUN_PID=
  exit "$rc"
}
