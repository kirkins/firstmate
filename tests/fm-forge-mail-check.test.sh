#!/usr/bin/env bash
# Behavior tests for bin/fm-forge-mail-check.sh, the standing forge-mailbox
# check.
#
# Two surfaces are exercised through their executable interfaces:
#
#   * arming/disarming state/forge-mail.check.sh with its trust binding,
#     including the refusal paths (symlink at the shim path, missing plane,
#     an unconfigured home that would watch silently forever);
#
#   * the `check` action itself, which runs the real fm-forge-mail.sh poll
#     against a scratch home whose fake forge decides the outcome. The cases
#     that matter are the reporting contract: a successful poll that surfaces
#     new mail emits one wake line, a repeated pre-wake failure reports once
#     then silences, an unconfigured home stays silent, and a fail-closed
#     poll that already queued a wake, or a timeout, always doorbells.
#
# No case ever contacts a real forge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-forge-mail-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-forge-mail-check)
FAKEBIN="$TMP_ROOT/fakebin"
FORGE_ROOT="$TMP_ROOT/forge"
TEST_HOST=git.test.invalid

# The same fake forge the plane tests use; see tests/fm-forge-mail.test.sh
# for the fixture contract.
make_fake_tools() {
  mkdir -p "$FAKEBIN" "$FORGE_ROOT"
  cat > "$FAKEBIN/secret-tool" <<SH
#!/usr/bin/env bash
if [ "\$1" = lookup ] && [ "\$2" = service ] && [ "\$3" = "${TEST_HOST}/forgejo-mail/drain" ]; then
  printf '%s' "faketoken0123456789abcdef"
fi
exit 0
SH
  cat > "$FAKEBIN/curl" <<SH
#!/usr/bin/env bash
[ "\${FM_FAKE_CURL_SLEEP:-0}" = 0 ] || sleep "\$FM_FAKE_CURL_SLEEP"
[ -z "\${FM_FAKE_CURL_FAIL:-}" ] || exit 1
root="\${FM_FAKE_FORGE_ROOT:?}"
out=/dev/null
method=GET
url=
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out=\$2; shift 2 ;;
    -X) method=\$2; shift 2 ;;
    https://*) url=\$1; shift ;;
    *) shift ;;
  esac
done
code=200
case "\$method:\$url" in
  GET:*"/api/v1/repos/own/mailbox")
    cat "\$root/repo.json" > "\$out" ;;
  GET:*"/api/v1/repos/own/mailbox/issues?"*)
    cat "\$root/issues.json" > "\$out" ;;
  *) code=404; : > "\$out" ;;
esac
printf '%s\n' "\$code"
SH
  chmod +x "$FAKEBIN/secret-tool" "$FAKEBIN/curl"
}

write_repo() {
  printf '{"id":%s,"full_name":"own/mailbox"}\n' "$1" > "$FORGE_ROOT/repo.json"
}

mk_issue() {
  jq -nc --argjson n "$1" --arg login "$2" --arg title "$3" --arg body "${4:-}" \
    '{number:$n,state:"open",title:$title,body:$body,user:{login:$login},labels:[{name:"mail"}]}'
}

set_issues() {
  {
    printf '['
    local first=1 obj
    for obj in "$@"; do
      [ "$first" = 1 ] || printf ','
      first=0
      printf '%s' "$obj"
    done
    printf ']'
  } > "$FORGE_ROOT/issues.json"
}

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

write_env() {
  local home=$1
  printf 'FM_FORGE_MAIL_HOST=%s\nFM_FORGE_MAIL_REPO=own/mailbox\n' "$TEST_HOST" > "$home/.env"
}

# run_check <home> [env-assignments...] : the check action against one home.
run_check() {
  local home=$1 out rc=0
  shift
  env -u FM_FORGE_MAIL_HOST -u FM_FORGE_MAIL_REPO -u FM_FORGE_MAIL_CHECK_BUDGET \
    FM_CHECK_TIMEOUT=30 \
    FM_FAKE_FORGE_ROOT="$FORGE_ROOT" \
    FM_FAKE_FORGE_HOST="$TEST_HOST" \
    "$@" FM_HOME="$home" PATH="$FAKEBIN:$PATH" \
    "$CHECK" check
}

test_help_and_usage() {
  local out rc=0
  out=$("$CHECK" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "check" "--help lists the check action"
  assert_contains "$out" "arm" "--help lists the arm action"
  assert_contains "$out" "disarm" "--help lists the disarm action"
  rc=0
  out=$("$CHECK" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown action must exit 2"
  assert_contains "$out" "unknown action" "unknown action is refused loudly"
  out=$(FM_FORGE_MAIL_CHECK_BUDGET=3 "$CHECK" check 2>&1) || rc=$?
  expect_code 2 "$rc" "an out-of-range budget must exit 2"
  assert_contains "$out" "5 to 25" "the budget error names the valid range"
  pass "fm-forge-mail-check: help, usage, and budget validation plumbing"
}

test_arm_writes_and_binds_the_check_and_disarm_removes_it() {
  local home out
  home=$(make_home arm)
  write_env "$home"
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "arm must succeed: $out"
  assert_contains "$out" "armed: state/forge-mail.check.sh" "arm names the shim it wrote"
  assert_present "$home/state/forge-mail.check.sh" "arm writes the check shim"
  assert_present "$home/state/forge-mail.check-trust" "arm binds the shim for the watcher"
  assert_contains "$(cat "$home/state/forge-mail.check.sh")" "fm-forge-mail-check.sh check" "shim dispatches the check action"
  assert_contains "$(cat "$home/state/forge-mail.check.sh")" "FM_HOME=$home" "shim pins the absolute home"
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "re-arm must succeed: $out"
  assert_contains "$out" "armed" "re-arm stays armed"
  out=$(FM_HOME="$home" "$CHECK" disarm 2>&1) || fail "disarm must succeed: $out"
  assert_absent "$home/state/forge-mail.check.sh" "disarm removes the check shim"
  assert_absent "$home/state/forge-mail.check-trust" "disarm removes the trust binding"
  assert_absent "$home/state/.forge-mail-check" "disarm removes the report record"
  pass "fm-forge-mail-check: arm writes and binds, re-arm is idempotent, disarm removes"
}

test_arm_resolves_a_relative_home_into_the_shim() {
  local home rel out
  home=$(make_home relative)
  write_env "$home"
  rel="$(basename "$home")"
  out=$(cd "$TMP_ROOT" && env FM_HOME="$rel" "$CHECK" arm 2>&1) || fail "arm with a relative FM_HOME must succeed: $out"
  assert_contains "$(cat "$home/state/forge-mail.check.sh")" "export FM_HOME=$home" "the shim pins the resolved absolute home, not the relative spelling"
  pass "fm-forge-mail-check: arm resolves a relative home into the shim"
}

test_arm_refuses_a_symlink_at_the_shim_path() {
  local home target out rc=0
  home=$(make_home symlink)
  write_env "$home"
  mkdir -p "$TMP_ROOT/symlink-target"
  target="$TMP_ROOT/symlink-target/evil.sh"
  printf '#!/usr/bin/env bash\necho pwned\n' > "$target"
  chmod +x "$target"
  ln -s "$target" "$home/state/forge-mail.check.sh"
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must refuse a symlink at the shim path"
  assert_contains "$out" "could not write" "the refusal is named"
  assert_absent "$home/state/forge-mail.check-trust" "no trust binding is written for a symlinked shim"
  pass "fm-forge-mail-check: arm refuses to follow a symlink at the shim path"
}

test_arm_refuses_an_unconfigured_home() {
  local home out rc=0
  home=$(make_home unconfigured)
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm on an unconfigured home must fail"
  assert_contains "$out" "FM_FORGE_MAIL_HOST" "the refusal names the first missing key"
  assert_contains "$out" ".env" "the refusal points at the home's .env"
  assert_absent "$home/state/forge-mail.check.sh" "no shim is written for an unconfigured home"
  pass "fm-forge-mail-check: arming an unconfigured home is refused, not silently armed"
}

test_check_silent_on_an_unconfigured_home() {
  local home out rc=0
  home=$(make_home off)
  out=$(run_check "$home") || rc=$?
  expect_code 0 "$rc" "check on an unconfigured home exits 0"
  assert_equals "" "$out" "the inert poll keeps the check silent"
  assert_absent "$home/state/.wake-queue" "nothing is queued for an unconfigured home"
  pass "fm-forge-mail-check: an unconfigured home's check is a silent no-op"
}

test_check_silent_on_a_proven_noop_poll() {
  local home out rc=0
  home=$(make_home noop)
  write_env "$home"
  write_repo 70001
  # An empty mailbox: a successful poll with nothing to surface.
  set_issues
  out=$(run_check "$home") || rc=$?
  expect_code 0 "$rc" "first check must exit 0"
  assert_equals "" "$out" "a poll with no new mail prints nothing"
  assert_present "$home/state/.forge-mail-check" "the report record exists"
  rc=0
  out=$(run_check "$home") || rc=$?
  expect_code 0 "$rc" "second check must exit 0"
  assert_equals "" "$out" "a repeated proven no-op stays silent"
  pass "fm-forge-mail-check: a proven no-op poll keeps the check silent"
}

test_check_reports_new_mail_once() {
  local home out rc=0
  home=$(make_home newmail)
  write_env "$home"
  write_repo 70001
  set_issues "$(mk_issue 7 sender "First" "body")"
  out=$(run_check "$home") || rc=$?
  expect_code 0 "$rc" "the surfacing check must exit 0"
  assert_contains "$out" "forge-mail: new mail: woke for own/mailbox#7" "the check emits one line naming the surfaced message"
  # The poll already queued the durable wake; the second run has nothing new.
  rc=0
  out=$(run_check "$home") || rc=$?
  expect_code 0 "$rc" "the second check must exit 0"
  assert_equals "" "$out" "the surfaced message is not re-reported"
  pass "fm-forge-mail-check: new mail doorbells exactly once"
}

test_check_reports_a_pre_wake_failure_once_then_silences() {
  local home out rc=0
  home=$(make_home prewake)
  write_env "$home"
  write_repo 70001
  set_issues "$(mk_issue 7 sender "First" "body")"
  out=$(run_check "$home" FM_FAKE_CURL_FAIL=1) || rc=$?
  expect_code 0 "$rc" "the check itself exits 0 on a failed poll"
  assert_contains "$out" "forge-mail: could not reach" "a first failure reports one line"
  rc=0
  out=$(run_check "$home" FM_FAKE_CURL_FAIL=1) || rc=$?
  expect_code 0 "$rc" "the repeated failure check must exit 0"
  assert_equals "" "$out" "a repeated identical pre-wake failure silences"
  pass "fm-forge-mail-check: a repeated pre-wake failure reports once then silences"
}

test_check_timeout_always_doorbells() {
  local home out rc=0
  home=$(make_home slow)
  write_env "$home"
  write_repo 70001
  set_issues "$(mk_issue 7 sender "First" "body")"
  out=$(run_check "$home" FM_FORGE_MAIL_CHECK_BUDGET=5 FM_FAKE_CURL_SLEEP=10) || rc=$?
  expect_code 0 "$rc" "the timed-out check itself exits 0"
  assert_contains "$out" "did not finish within the 5s budget" "a timeout reports one line naming the budget"
  rc=0
  out=$(run_check "$home" FM_FORGE_MAIL_CHECK_BUDGET=5 FM_FAKE_CURL_SLEEP=10) || rc=$?
  expect_code 0 "$rc" "the repeated timed-out check must exit 0"
  assert_contains "$out" "did not finish within the 5s budget" "a repeated timeout still doorbells"
  assert_equals "1" "$(grep -c . <<<"$out")" "the timeout report is one line"
  pass "fm-forge-mail-check: a poll that does not finish always doorbells"
}

test_check_fail_closed_after_queue_doorbells() {
  # Triple write fault: the poll queues its wake, cannot record or roll it
  # back, and fails closed with the row still queued. That row is durable
  # work the watcher must surface, so the check prints even though the poll
  # failed - and the earlier pre-wake silence never applies to it.
  local home out rc=0
  home=$(make_home failclosed)
  write_env "$home"
  write_repo 70001
  set_issues "$(mk_issue 12 sender "First" "body")"
  mkdir -p "$home/state"
  printf 'generation=70001\n' > "$home/state/.forge-mail-seen"
  : > "$home/state/.forge-mail-woken"
  : > "$home/state/.wake-queue"
  chmod 0400 "$home/state/.forge-mail-seen" "$home/state/.forge-mail-woken"
  chmod 0200 "$home/state/.wake-queue"
  [ -w "$home/state/.forge-mail-seen" ] && { echo "fixture unexpected: cursor still writable"; return 1; }
  [ -w "$home/state/.wake-queue" ] || { echo "fixture unexpected: queue not appendable"; return 1; }
  out=$(run_check "$home") || rc=$?
  expect_code 0 "$rc" "the check itself exits 0 on a fail-closed poll"
  assert_contains "$out" "the wake stays queued" "the fail-closed outcome is reported"
  assert_contains "$out" "forge-mail: " "the report carries the check's news prefix"
  chmod 0600 "$home/state/.forge-mail-seen" "$home/state/.forge-mail-woken"
  chmod 0644 "$home/state/.wake-queue"
  rc=0
  out=$(run_check "$home") || rc=$?
  expect_code 0 "$rc" "the healing check must exit 0"
  assert_equals "" "$out" "once healed, the check returns to proven no-op silence"
  assert_contains "$(cat "$home/state/.forge-mail-seen")" "12" "the healing poll recorded the retained row's number"
  pass "fm-forge-mail-check: a fail-closed poll with a queued wake doorbells, then heals"
}

make_fake_tools

test_help_and_usage
test_arm_writes_and_binds_the_check_and_disarm_removes_it
test_arm_resolves_a_relative_home_into_the_shim
test_arm_refuses_a_symlink_at_the_shim_path
test_arm_refuses_an_unconfigured_home
test_check_silent_on_an_unconfigured_home
test_check_silent_on_a_proven_noop_poll
test_check_reports_new_mail_once
test_check_reports_a_pre_wake_failure_once_then_silences
test_check_timeout_always_doorbells
test_check_fail_closed_after_queue_doorbells
