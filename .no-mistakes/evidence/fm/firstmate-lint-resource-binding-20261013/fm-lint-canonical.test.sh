#!/usr/bin/env bash
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/.fm-lint-resource-fixtures.sh"
canonical=/home/kirkins/Documents/firstmate
binding_fixture canonical
mkdir -p "$BINDING_REPO/bin/backends"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDING_REPO/bin/backends/fixture.sh"
BINDING_HOME=$canonical
plain_lint() {
  (
    cd "$BINDING_REPO"
    env -u FM_LINT_RESOURCE_TASK -u XDG_CONFIG_HOME -u XDG_STATE_HOME \
      BINDING_HOME="$canonical" BINDING_TRACE="$BINDING_TRACE" \
      BINDING_STRAGGLER=1 BINDING_EXIT="${BINDING_EXIT:-0}" \
      FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS=1 \
      FM_LINT_TELEMETRY="$BINDING_TRACE/telemetry.tsv" \
      PATH="$BINDING_FAKEBIN:$PATH" sh -c 'bin/fm-lint.sh'
  )
}
for expected in 0 7; do
  BINDING_EXIT=$expected
  : > "$BINDING_TRACE/children"
  rc=0
  plain_lint > "$BINDING_TRACE/plain.$expected.log" 2>&1 || rc=$?
  cat "$BINDING_TRACE/plain.$expected.log"
  expect_code "$expected" "$rc" 'canonical plain entrypoint must propagate analysis exit'
  assert_grep 'jobs=1 MemoryMax=1024M memory.max=1073741824' "$BINDING_TRACE/plain.$expected.log" 'actual operator cap and jobs were not enforced'
  assert_grep "helper=$canonical/bin/fm-heavy-slot.sh" "$BINDING_TRACE/plain.$expected.log" 'plain lint did not use the canonical owner'
  assert_grep $'jobs\t1' "$BINDING_TRACE/telemetry.tsv" 'actual worker count was not one'
  [ -s "$BINDING_TRACE/children" ] || fail 'plain entrypoint ran no analysis child'
  while IFS= read -r child; do
    assert_contains "$child" 'cap=1073741824 held task=lint-' 'analysis did not see its real kernel cap and global hold'
    printf 'canonical child: %s\n' "$child"
  done < "$BINDING_TRACE/children"
  [ "$("$canonical/bin/fm-heavy-slot.sh" status)" = free ] || fail 'plain lint leaked its global slot'
  while IFS= read -r group; do
    if [ -f "/sys/fs/cgroup$group/cgroup.events" ]; then
      grep -q '^populated 0$' "/sys/fs/cgroup$group/cgroup.events" || fail 'plain lint left its scope populated'
    fi
  done < "$BINDING_TRACE/scopes"
  while IFS= read -r pid; do
    if kill -0 "$pid" 2>/dev/null; then
      case "$(ps -o stat= -p "$pid" | tr -d ' ')" in Z*|'') ;; *) fail 'plain lint left a separately grouped straggler running' ;; esac
    fi
  done < "$BINDING_TRACE/stragglers"
  [ ! -e "$BINDING_TRACE/overlap" ] || fail 'plain lint overlapped analysis'
  pass "canonical plain entrypoint: actual 1024MiB cap, one job, exit $expected, empty scope and free slot"
done
: > "$BINDING_TRACE/children"
"$canonical/bin/fm-heavy-slot.sh" acquire firstmate-lint-resource-binding-20261013 --estimate 1024
trap '"$canonical/bin/fm-heavy-slot.sh" release firstmate-lint-resource-binding-20261013' EXIT
rc=0
plain_lint > "$BINDING_TRACE/contention.log" 2>&1 || rc=$?
expect_code 6 "$rc" 'plain lint must refuse the actual global holder'
cat "$BINDING_TRACE/contention.log"
assert_grep "held by task 'firstmate-lint-resource-binding-20261013'" "$BINDING_TRACE/contention.log" 'global refusal did not name its holder'
[ ! -s "$BINDING_TRACE/children" ] || fail 'global contention ran analysis'
rc=0
"$canonical/bin/fm-heavy-slot.sh" release lint-nonholder > "$BINDING_TRACE/nonholder.log" 2>&1 || rc=$?
expect_code 6 "$rc" 'non-holder cannot release actual global capacity'
cat "$BINDING_TRACE/nonholder.log"
assert_contains "$("$canonical/bin/fm-heavy-slot.sh" status)" 'held task=firstmate-lint-resource-binding-20261013' 'refused lint or non-holder cleared real capacity'
"$canonical/bin/fm-heavy-slot.sh" release firstmate-lint-resource-binding-20261013
trap fm_test_cleanup EXIT
pass 'actual global contention names and preserves the holder; matching release frees capacity'
