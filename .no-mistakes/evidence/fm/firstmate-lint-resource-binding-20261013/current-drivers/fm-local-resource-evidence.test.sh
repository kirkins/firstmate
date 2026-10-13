#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
capture_cleanup() {
  local rc=$? case_dir
  set +x
  if [ -n "${BINDING_TMP:-}" ]; then
    for case_dir in "$BINDING_TMP"/*; do
      [ -d "$case_dir/trace" ] || continue
      mkdir -p "$LOCAL_EVIDENCE/binding-cases/$(basename "$case_dir")"
      cp -R "$case_dir/trace/." "$LOCAL_EVIDENCE/binding-cases/$(basename "$case_dir")/"
    done
  fi
  fm_test_cleanup
  return "$rc"
}
trap capture_cleanup EXIT
exec 9>"$LOCAL_EVIDENCE/binding-driver.trace.log"
BASH_XTRACEFD=9
set -x
. "$ROOT/tests/fm-lint-resource-binding.test.sh"
set +x
