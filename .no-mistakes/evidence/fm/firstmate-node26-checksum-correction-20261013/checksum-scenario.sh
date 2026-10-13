#!/usr/bin/env bash
set -u
scenario=$1
printf 'scenario=%s\n' "$scenario"
printf 'FM_LINT_JOBS=%s\n' "$FM_LINT_JOBS"
cgroup=$(cut -d: -f3 /proc/self/cgroup)
printf 'enforced_memory_max_bytes=%s\n' "$(cat "/sys/fs/cgroup$cgroup/memory.max")"
. "$PWD/.test-phase-checksum/focused-definitions.sh"
printf 'fixture_root=%s\n' "$TMP_ROOT"
if [ "$scenario" = portable ]; then
  if command -v sha256sum; then fail 'GNU sha256sum must be absent before the test builds its adapter'; fi
  printf 'SHA backend=%s\n' "$(command -v shasum)"
fi
# Observe the real CLI's output and extraction side effects without changing assertions.
eval "$(declare -f hands | sed '1s/hands/hands_original/')"
hands() {
  hands_original "$@"
  local mode=unknown arg
  for arg in "$@"; do case "$arg" in FM_FAKE_CHECKSUM_MODE=*) mode=${arg#*=} ;; esac; done
  printf 'prepare mode=%s exit=%s extraction=%s\n' "$mode" "$HANDS_STATUS" "$([ -e "$TMP_ROOT/extracted" ] && echo yes || echo no)"
  printf '%s\n' "$HANDS_STDOUT" "$HANDS_STDERR"
}
if [ "$scenario" = old ]; then HANDS="$PWD/.test-phase-checksum/old-installer.sh"; fi
if [ "$scenario" != portable ]; then test_fake_exec_restores_fixture_path_after_login; fi
# Xtrace records the real SHA backend invoked to compute the expected digest.
set -x
test_prepare_verifies_downloaded_archive_before_extraction
set +x
