#!/usr/bin/env bash
set -euo pipefail
scratch="$PWD/.test-phase-checksum"
evidence=/home/kirkins/.no-mistakes/evidence/01M4V016HPH5A3J4VTRRX6MZKS
export XDG_STATE_HOME="$scratch/state" FM_STATE_OVERRIDE="$scratch/state" FM_LINT_JOBS=1
bin/fm-heavy-slot.sh acquire checksum-focused --estimate 256 --expiry 600
trap 'bin/fm-heavy-slot.sh release checksum-focused' EXIT
for scenario in portable reordered old; do
  mkdir -p "$scratch/tmp/$scenario"
  printf 'existing archive sentinel\n' > "$scratch/host-tmp/fm-node.tar.xz"
  before=$(/usr/bin/sha256sum "$scratch/host-tmp/fm-node.tar.xz")
  : > "$scratch/login-$scenario.log"
  variant=normal
  [ "$scenario" != portable ] || variant=portable
  set +e
  systemd-run --user --scope -p MemoryMax=256M -- bwrap \
    --ro-bind / / --dev /dev --tmpfs /home --bind "$PWD" "$PWD" \
    --bind "$evidence" "$evidence" --bind "$scratch/host-tmp" /tmp \
    --unshare-net --die-with-parent --chdir "$PWD" -- \
    /usr/bin/env -i HOME="$scratch/home" TMPDIR="$scratch/tmp/$scenario" \
      PATH="$scratch/path/$variant" FM_LINT_JOBS=1 FM_TEST_SKIP_ORPHAN_REAP=1 \
      PHASE_LOGIN_LOG="$scratch/login-$scenario.log" \
      /usr/bin/bash "$scratch/scenario.sh" "$scenario" \
      > "$evidence/checksum-$scenario.log" 2>&1
  rc=$?
  set -e
  after=$(/usr/bin/sha256sum "$scratch/host-tmp/fm-node.tar.xz")
  [ "$before" = "$after" ]
  [ -z "$(ls -A "$scratch/tmp/$scenario")" ]
  if [ "$scenario" = old ]; then [ "$rc" -eq 1 ]; else [ "$rc" -eq 0 ]; fi
  {
    printf '\nobserved_regression_exit=%s\n' "$rc"
    printf 'private_archive_sentinel_preserved=%s\n' "$after"
    printf 'fixture_cleanup_after_exit=complete\n'
    printf 'login_PATH_reorder_events=%s\n' "$(wc -l < "$scratch/login-$scenario.log")"
    cat "$scratch/login-$scenario.log"
  } >> "$evidence/checksum-$scenario.log"
  printf '%s: expected exit %s; sentinel preserved; all fixture roots and registries removed\n' "$scenario" "$rc"
done
bin/fm-heavy-slot.sh status
/usr/bin/node --version
