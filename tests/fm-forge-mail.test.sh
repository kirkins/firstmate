#!/usr/bin/env bash
# Behavior tests for bin/fm-forge-mail.sh.
#
# fm-forge-mail.sh is a network Forgejo client, so these tests exercise the
# whole poll/read/ack surface against a fake forge (a fake secret-tool and a
# fake curl on PATH serving a fixture tree): the off-unless-configured
# contract, the journal-first wake transaction and its crash heals, the
# per-poll cap, the repo-id generation reset, the read and ack behavior, and
# the token's dedicated keyring slot and header-from-fd hygiene. All cases go
# through the executable public interface and never assert internal source
# bytes. No case ever contacts a real forge.
#
# Crash-semantics tests use issue number 12 against generation 70001 so a
# substring assertion on the cursor can never match the generation line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLANE="$ROOT/bin/fm-forge-mail.sh"
TMP_ROOT=$(fm_test_tmproot fm-forge-mail)
FAKEBIN="$TMP_ROOT/fakebin"
FORGE_ROOT="$TMP_ROOT/forge"
TEST_HOST=git.test.invalid
DRAIN_TOKEN=faketoken0123456789abcdef

make_fake_tools() {
  mkdir -p "$FAKEBIN" "$FORGE_ROOT"
  cat > "$FAKEBIN/secret-tool" <<SH
#!/usr/bin/env bash
# Fake keyring lookup. Answers only the slot the plane names, so a test can
# pin the dedicated-slot contract by switching FM_FAKE_TOKEN_MODE.
if [ "\$1" != lookup ] || [ "\$2" != service ]; then
  exit 1
fi
case "\${FM_FAKE_TOKEN_MODE:-drain}" in
  drain)
    [ "\$3" = "${TEST_HOST}/forgejo-mail/drain" ] || exit 1
    printf '%s' "$DRAIN_TOKEN" ;;
  omarchy)
    [ "\$3" = "${TEST_HOST}/forgejo-cli/omarchy" ] || exit 1
    printf '%s' "$DRAIN_TOKEN" ;;
  *) exit 1 ;;
esac
SH
  cat > "$FAKEBIN/curl" <<SH
#!/usr/bin/env bash
# Fake Forgejo API client. Serves the fixture tree at FM_FAKE_FORGE_ROOT and
# records every invocation for hygiene assertions. FM_FAKE_CURL_FAIL makes
# curl itself fail (offline), FM_FAKE_CURL_SLEEP stalls, and the code and
# state overrides shape ack outcomes.
[ -z "\${FM_FAKE_CURL_LOG:-}" ] || printf '%s\n' "\$*" >> "\$FM_FAKE_CURL_LOG"
[ "\${FM_FAKE_CURL_SLEEP:-0}" = 0 ] || sleep "\$FM_FAKE_CURL_SLEEP"
[ -z "\${FM_FAKE_CURL_FAIL:-}" ] || exit 1
root="\${FM_FAKE_FORGE_ROOT:?}"
out=/dev/null
method=GET
url=
data=
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out=\$2; shift 2 ;;
    -X) method=\$2; shift 2 ;;
    --data) data=\$2; shift 2 ;;
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
  GET:*"/api/v1/repos/own/mailbox/issues/"*)
    n=\${url##*/issues/}
    if [ -f "\$root/issue-\$n.json" ]; then
      cat "\$root/issue-\$n.json" > "\$out"
    else
      code=404
      : > "\$out"
    fi ;;
  POST:*"/comments")
    [ -z "\${FM_FAKE_CURL_BODIES:-}" ] || printf '%s\n' "\$data" >> "\$FM_FAKE_CURL_BODIES"
    code=\${FM_FAKE_CURL_COMMENT_CODE:-201}
    printf '{"id":1}\n' > "\$out" ;;
  PATCH:*)
    [ -z "\${FM_FAKE_CURL_BODIES:-}" ] || printf '%s\n' "\$data" >> "\$FM_FAKE_CURL_BODIES"
    code=\${FM_FAKE_CURL_CLOSE_CODE:-200}
    printf '{"number":%s,"state":"%s","title":"x","body":"b","user":{"login":"bot"}}\n' \
      "\${url##*/issues/}" "\${FM_FAKE_CURL_CLOSE_STATE:-closed}" > "\$out" ;;
  *) code=404; : > "\$out" ;;
esac
printf '%s\n' "\$code"
SH
  chmod +x "$FAKEBIN/secret-tool" "$FAKEBIN/curl"
}

# write_repo <id>: the mailbox repo fixture, whose id is the generation key.
write_repo() {
  printf '{"id":%s,"full_name":"own/mailbox"}\n' "$1" > "$FORGE_ROOT/repo.json"
}

# mk_issue <n> <login> <title> [body]: one issue object literal.
mk_issue() {
  jq -nc --argjson n "$1" --arg login "$2" --arg title "$3" --arg body "${4:-}" \
    '{number:$n,state:"open",title:$title,body:$body,user:{login:$login},labels:[{name:"mail"}]}'
}

# set_issues <json>...: the open-mail list fixture from issue objects. Tests
# pass newest-first, as the API returns it, so the poll's oldest-first sort is
# exercised by every wake-order assertion.
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

# run_plane <home> <args...>: the plane with the standard fake configuration.
# Unconfigured cases call "$PLANE" directly instead.
run_plane() {
  local home=$1
  shift
  FM_HOME="$home" \
  FM_FORGE_MAIL_HOST="$TEST_HOST" \
  FM_FORGE_MAIL_REPO=own/mailbox \
  FM_FAKE_FORGE_ROOT="$FORGE_ROOT" \
  FM_FAKE_FORGE_HOST="$TEST_HOST" \
  FM_FAKE_CURL_LOG="$FORGE_ROOT/curl.log" \
  PATH="$FAKEBIN:$PATH" \
    "$PLANE" "$@"
}

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home"
  printf '%s\n' "$home"
}

wake_queue_rows() {
  local rows
  rows=$(grep -c $'\tcheck\tforge-mail:' "${1:?}/state/.wake-queue" 2>/dev/null || true)
  printf '%s\n' "${rows:-0}"
}

test_unconfigured_poll_is_a_hard_noop() {
  local home out rc=0
  home=$(make_home unconfigured)
  out=$(env -u FM_FORGE_MAIL_HOST -u FM_FORGE_MAIL_REPO FM_HOME="$home" \
    PATH="$FAKEBIN:$PATH" "$PLANE" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "unconfigured poll must exit 0"
  assert_equals "" "$out" "unconfigured poll prints nothing at all"
  assert_absent "$home/state/.wake-queue" "unconfigured poll queues no wake"
  out=$(env -u FM_FORGE_MAIL_HOST -u FM_FORGE_MAIL_REPO FM_HOME="$home" \
    "$PLANE" status 2>&1) || rc=$?
  expect_code 0 "$rc" "unconfigured status must exit 0"
  assert_contains "$out" "off" "unconfigured status names its off state"
  assert_contains "$out" "FM_FORGE_MAIL_HOST" "off status names the missing keys"
  pass "fm-forge-mail: an unconfigured home is a hard no-op, poll and status alike"
}

test_partial_configuration_is_still_off() {
  local home out rc=0
  home=$(make_home partial)
  out=$(env FM_FORGE_MAIL_HOST="$TEST_HOST" FM_HOME="$home" \
    PATH="$FAKEBIN:$PATH" "$PLANE" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "half-configured poll stays a silent no-op"
  assert_equals "" "$out" "half-configured poll prints nothing"
  out=$(env FM_FORGE_MAIL_HOST="$TEST_HOST" FM_HOME="$home" \
    PATH="$FAKEBIN:$PATH" "$PLANE" read 7 2>&1) || rc=$?
  expect_code 1 "$rc" "read on a half-configured home fails"
  assert_contains "$out" "FM_FORGE_MAIL_REPO" "read names the missing key"
  pass "fm-forge-mail: either missing key keeps the plane off, and read names the gap"
}

test_env_overrides_env_file() {
  local home out
  home=$(make_home envfile)
  printf 'FM_FORGE_MAIL_HOST=fromfile.invalid\nFM_FORGE_MAIL_REPO=own/mailbox\n' > "$home/.env"
  out=$(run_plane "$home" status 2>&1)
  assert_contains "$out" "forge host: $TEST_HOST" "environment host wins over .env"
  assert_contains "$out" "mailbox: own/mailbox" "the other key still comes from .env"
  out=$(env -u FM_FORGE_MAIL_HOST FM_HOME="$home" FM_FAKE_FORGE_ROOT="$FORGE_ROOT" \
    FM_FAKE_FORGE_HOST=fromfile.invalid PATH="$FAKEBIN:$PATH" "$PLANE" status 2>&1)
  assert_contains "$out" "forge host: fromfile.invalid" ".env supplies the host when the environment is unset"
  pass "fm-forge-mail: environment values override the .env file per key"
}

test_status_touches_no_network_or_credentials() {
  local home marker out rc=0
  home=$(make_home statusnet)
  # A curl that would leave evidence: status must never invoke it, and the
  # fake secret-tool is absent from this PATH so any credential read would
  # also have to go through the logged stub.
  marker="$FORGE_ROOT/status-curl-marker"
  mkdir -p "$TMP_ROOT/statusbin"
  printf '#!/usr/bin/env bash\ntouch %s\nexit 99\n' "$(printf '%q' "$marker")" > "$TMP_ROOT/statusbin/curl"
  chmod +x "$TMP_ROOT/statusbin/curl"
  write_repo 70001
  set_issues "$(mk_issue 7 sender "First" "body")"
  out=$(FM_HOME="$home" FM_FORGE_MAIL_HOST="$TEST_HOST" FM_FORGE_MAIL_REPO=own/mailbox \
    PATH="$TMP_ROOT/statusbin:$PATH" "$PLANE" status 2>&1) || rc=$?
  expect_code 0 "$rc" "status must succeed without curl or a keyring"
  assert_absent "$marker" "status never invokes curl"
  assert_contains "$out" "mailbox: own/mailbox" "status prints the configured mailbox"
  pass "fm-forge-mail: status reads only local records"
}

test_invalid_host_and_repo_are_rejected() {
  local home out rc=0
  home=$(make_home invalid)
  out=$(FM_HOME="$home" FM_FORGE_MAIL_HOST="bad/host" FM_FORGE_MAIL_REPO=own/mailbox \
    PATH="$FAKEBIN:$PATH" "$PLANE" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "a host with a path separator must be refused"
  assert_contains "$out" "FM_FORGE_MAIL_HOST" "the refusal names the key"
  out=$(FM_HOME="$home" FM_FORGE_MAIL_HOST="$TEST_HOST" FM_FORGE_MAIL_REPO="nodashes" \
    PATH="$FAKEBIN:$PATH" "$PLANE" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "a repo without owner/name must be refused"
  assert_contains "$out" "owner/name" "the refusal names the required shape"
  pass "fm-forge-mail: malformed endpoints are rejected before any request"
}

test_missing_drain_token_fails_naming_the_slot() {
  local home out rc=0
  home=$(make_home notoken)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 7 sender "First" "body")"
  out=$(FM_FAKE_TOKEN_MODE=empty run_plane "$home" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "poll must fail without the drain token"
  assert_contains "$out" "forgejo-mail/drain" "the failure names the dedicated keyring slot"
  assert_equals "0" "$(wake_queue_rows "$home")" "nothing is woken without a token"
  pass "fm-forge-mail: a missing drain token is a named prerequisite, never a silent skip"
}

test_drain_token_uses_the_dedicated_slot() {
  local home out rc=0
  home=$(make_home wrongslot)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 7 sender "First" "body")"
  # The PR-merge slot answering instead of the dedicated one must not satisfy
  # the plane: the least-privilege token is load-bearing, not interchangeable.
  out=$(FM_FAKE_TOKEN_MODE=omarchy run_plane "$home" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "poll must fail when only the PR-merge slot answers"
  assert_contains "$out" "forgejo-mail/drain" "the failure still names the dedicated slot"
  pass "fm-forge-mail: the drain token is read from its dedicated slot only"
}

test_token_never_reaches_curl_argv() {
  local home out rc=0 log
  home=$(make_home tokenhygiene)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 7 sender "First" "body")"
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "poll must succeed for the hygiene capture"
  log=$(cat "$FORGE_ROOT/curl.log")
  assert_not_contains "$log" "$DRAIN_TOKEN" "the drain token never appears in curl argv"
  assert_not_contains "$log" "Authorization" "no auth header is passed as an argument"
  out=$(FM_FAKE_CURL_BODIES="$FORGE_ROOT/ack-bodies.log" run_plane "$home" ack 7 --note "done" 2>&1) || rc=$?
  expect_code 0 "$rc" "ack must succeed for the hygiene capture"
  log=$(cat "$FORGE_ROOT/curl.log")
  assert_not_contains "$log" "$DRAIN_TOKEN" "the drain token stays out of argv through ack"
  pass "fm-forge-mail: the token reaches curl only through the fd-read header"
}

test_poll_wakes_each_new_issue_once_and_only_reads() {
  local home out rc=0 queue
  home=$(make_home basic)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 13 hermes "Second" "hello")" "$(mk_issue 12 chatgpt-bot "Findings" $'corr: abc\nline two')"
  : > "$FORGE_ROOT/curl.log"
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "first poll must succeed"
  assert_contains "$out" "woke for own/mailbox#12" "the poll wakes issue 12"
  assert_contains "$out" "woke for own/mailbox#13" "the poll wakes issue 13"
  queue=$(cat "$home/state/.wake-queue")
  assert_contains "$queue" "forge-mail:70001/12" "the wake key is generation-scoped"
  assert_contains "$queue" "check: forge-mail own/mailbox#12 - message from chatgpt-bot - Findings" \
    "the payload names the issue and the sender principal"
  assert_contains "$queue" "check: forge-mail own/mailbox#13 - message from hermes - Second" \
    "the second payload names its own sender"
  assert_contains "$(cat "$home/state/.forge-mail-seen")" "12" "the cursor records the surfaced number"
  assert_contains "$(cat "$home/state/.forge-mail-woken")" $'70001\t12' "the journal records generation and number"
  assert_contains "$(cat "$home/state/forge-mail-inbox/12.json")" "corr: abc" "the poll stashes the body for offline reading"
  # BODY.PEEK discipline: the poll only reads.
  assert_equals " -X GET " "$(grep -o ' -X [A-Z]* ' "$FORGE_ROOT/curl.log" | sort -u)" \
    "the poll issues GET requests only"
  rc=0
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "second poll must succeed"
  assert_contains "$out" "no new mail" "a re-poll of surfaced issues reports no new mail"
  expect_code 2 "$(wake_queue_rows "$home")" "two issues wake exactly once each"
  pass "fm-forge-mail: poll surfaces each new issue once, reads only, and stashes bodies"
}

test_poll_cap_bounds_wakes_per_run() {
  local home out rc=0
  home=$(make_home cap)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 5 s "Five" b)" "$(mk_issue 4 s "Four" b)" "$(mk_issue 3 s "Three" b)"
  out=$(FM_FORGE_MAIL_POLL_MAX_WAKES=2 run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "capped poll must succeed"
  expect_code 2 "$(wake_queue_rows "$home")" "the cap bounds one poll to two wakes"
  assert_contains "$out" "per-poll wake cap (2) reached" "the cap is reported"
  assert_contains "$out" "woke for own/mailbox#3" "the oldest messages surface first under the cap"
  rc=0
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "follow-up poll must succeed"
  assert_contains "$out" "woke for own/mailbox#5" "the capped remainder surfaces on the next poll"
  expect_code 3 "$(wake_queue_rows "$home")" "all three issues surface across two polls"
  pass "fm-forge-mail: the per-poll wake cap bounds the queue without dropping mail"
}

test_poll_cap_defaults_to_ten() {
  local home out rc=0 i
  home=$(make_home capdefault)
  make_fake_tools
  write_repo 70001
  {
    printf '['
    for i in $(seq 12 -1 1); do
      [ "$i" = 12 ] || printf ','
      printf '%s' "$(mk_issue "$i" s "Msg $i" b)"
    done
    printf ']'
  } > "$FORGE_ROOT/issues.json"
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "default-cap poll must succeed"
  expect_code 10 "$(wake_queue_rows "$home")" "the default cap wakes at most ten"
  assert_contains "$out" "per-poll wake cap (10) reached" "the default cap is reported"
  pass "fm-forge-mail: the wake cap defaults to ten"
}

test_poll_resurfaces_number_after_generation_reset() {
  local home out rc=0
  home=$(make_home generation)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 5 sender "Original" "first body")"
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "first-generation poll must succeed"
  assert_contains "$out" "woke for own/mailbox#5" "the first generation wakes number 5"
  # A stale stash from the old repo proves the reset prunes it.
  printf '{"number":4,"stale":true}\n' > "$home/state/forge-mail-inbox/4.json"
  # Deletion and recreation: a new repo id with the same number reused.
  write_repo 80002
  set_issues "$(mk_issue 5 sender "Recreated" "second body")"
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "second-generation poll must succeed"
  assert_contains "$out" "woke for own/mailbox#5" "a reused number wakes again under the new repo id"
  assert_contains "$(cat "$home/state/.wake-queue")" "forge-mail:80002/5" "the new wake is keyed by the new generation"
  assert_equals "generation=80002" "$(sed -n '1p' "$home/state/.forge-mail-seen")" "the cursor carries the new generation"
  assert_absent "$home/state/forge-mail-inbox/4.json" "old-generation stashes are pruned"
  pass "fm-forge-mail: a repo recreation resets numbering without suppressing reused numbers"
}

test_poll_stale_journal_cannot_suppress_after_reset() {
  local home out rc=0
  home=$(make_home stalejournal)
  make_fake_tools
  write_repo 80002
  set_issues "$(mk_issue 5 sender "Recreated" "body")"
  # A journal and cursor from the pre-recreation repo claiming number 5.
  mkdir -p "$home/state"
  printf 'generation=70001\n' > "$home/state/.forge-mail-seen"
  printf '70001\t5\n' > "$home/state/.forge-mail-woken"
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "poll with stale prior-generation records must succeed"
  assert_contains "$out" "woke for own/mailbox#5" "prior-generation evidence never suppresses the reused number"
  pass "fm-forge-mail: stale journal evidence is cleared on a generation change"
}

test_poll_journal_failure_never_cursor_records() {
  # A number must never be cursor-recorded without the journal recording its
  # wake; a journal that cannot be written fails the poll instead of letting
  # the cursor silently suppress the message.
  local home out rc=0
  home=$(make_home journalfail)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 12 sender "First" "body")"
  mkdir -p "$home/state"
  printf 'generation=70001\n' > "$home/state/.forge-mail-seen"
  : > "$home/state/.forge-mail-woken"
  chmod 0400 "$home/state/.forge-mail-woken"
  [ -w "$home/state/.forge-mail-woken" ] && { echo "fixture unexpected: journal still writable"; return 1; }
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "poll must fail when the journal cannot be written"
  assert_not_contains "$out" "woke for own/mailbox#12" "no wake is reported before the journal commits"
  assert_not_contains "$(cat "$home/state/.forge-mail-seen")" "12" "a failed journal write must not cursor-record the number"
  assert_equals "0" "$(wake_queue_rows "$home")" "the rolled-back wake leaves nothing ackable"
  chmod 0600 "$home/state/.forge-mail-woken"
  rc=0
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "retry poll must succeed"
  assert_contains "$out" "woke for own/mailbox#12" "the retry surfaces the message exactly once"
  expect_code 1 "$(wake_queue_rows "$home")" "exactly one wake survives the retry"
  pass "fm-forge-mail: a journal write failure never cursor-records a suppressed message"
}

test_poll_journal_recovers_wake_after_drain_ack() {
  # A poll killed after its wake append but before its cursor write, followed
  # by the drain acknowledging that wake, leaves the number only in the
  # journal. The next poll records it without re-waking.
  local home out rc=0
  home=$(make_home journalheal)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 12 sender "First" "body")"
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "first poll must succeed"
  assert_contains "$out" "woke for own/mailbox#12" "the first poll wakes number 12"
  printf 'generation=70001\n' > "$home/state/.forge-mail-seen"
  grep -v $'check\tforge-mail:70001/12' "$home/state/.wake-queue" > "$TMP_ROOT/acked-queue" || true
  mv "$TMP_ROOT/acked-queue" "$home/state/.wake-queue"
  rc=0
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "recovery poll must succeed"
  assert_not_contains "$out" "woke for own/mailbox#12" "the recovery never re-wakes the acked message"
  assert_contains "$(cat "$home/state/.forge-mail-seen")" "12" "journal heal restores the cursor record"
  assert_equals "" "$(cat "$home/state/.forge-mail-woken" 2>/dev/null)" "the journal clears once every number is recorded"
  pass "fm-forge-mail: the journal recovers a wake the drain already acknowledged"
}

test_poll_heals_queued_wake_without_records() {
  # A poll killed between the queue append and the evidence writes leaves the
  # number only as a queued key. The next poll records it without duplicating.
  local home out rc=0
  home=$(make_home queueheal)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 12 sender "First" "body")"
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "first poll must succeed"
  assert_contains "$out" "woke for own/mailbox#12" "the first poll wakes number 12"
  printf 'generation=70001\n' > "$home/state/.forge-mail-seen"
  : > "$home/state/.forge-mail-woken"
  expect_code 1 "$(wake_queue_rows "$home")" "the wake row survives the simulated interruption"
  rc=0
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "healing poll must succeed"
  assert_not_contains "$out" "woke for own/mailbox#12" "the healing poll must not duplicate the queued message"
  assert_contains "$(cat "$home/state/.forge-mail-seen")" "12" "the queued key records the number"
  expect_code 1 "$(wake_queue_rows "$home")" "the queued wake row stays exactly once"
  pass "fm-forge-mail: a queued wake with no records heals without duplicating"
}

test_poll_fail_closed_row_is_kept_for_healing() {
  # Triple write fault: journal and cursor cannot be written and the queue
  # cannot be read for the rollback. The wake row must stay queued (fail
  # closed, delivered by the drain) and the next poll heals it in place.
  local home out rc=0
  home=$(make_home failclosed)
  make_fake_tools
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
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "poll must fail when the wake can be neither recorded nor rolled back"
  assert_contains "$out" "the wake stays queued" "the failure reports the fail-closed outcome"
  chmod 0600 "$home/state/.forge-mail-seen" "$home/state/.forge-mail-woken"
  chmod 0644 "$home/state/.wake-queue"
  # The queue was write-only during the fault, so the retained row is counted
  # only now that it is readable again.
  expect_code 1 "$(grep -c 'forge-mail:70001/12' "$home/state/.wake-queue" 2>/dev/null || true)" "the row stayed queued exactly once"
  rc=0
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "retry poll must succeed after access is restored"
  assert_contains "$out" "no new mail" "the retry heals the retained row without re-waking"
  assert_contains "$(cat "$home/state/.forge-mail-seen")" "12" "the retry records the retained row's number"
  pass "fm-forge-mail: a fail-closed wake stays queued and heals without a duplicate"
}

test_poll_network_failure_fails_closed_and_releases_the_lock() {
  local home out rc=0
  home=$(make_home offline)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 12 sender "First" "body")"
  out=$(FM_FAKE_CURL_FAIL=1 run_plane "$home" poll 2>&1) || rc=$?
  expect_code 1 "$rc" "an unreachable forge fails the poll"
  assert_not_contains "$out" "woke for" "nothing is woken while offline"
  assert_not_contains "$out" "no new mail" "an offline poll is not reported as no new mail"
  expect_code 0 "$(wake_queue_rows "$home")" "no wake is queued while offline"
  rc=0
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "the later poll proves the seen lock was released"
  assert_contains "$out" "woke for own/mailbox#12" "the later poll surfaces the message"
  pass "fm-forge-mail: an unreachable forge fails closed and releases the lock"
}

test_read_prints_principal_and_body() {
  local home out rc=0
  home=$(make_home readsingle)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 7 chatgpt-bot "Findings" $'corr: abc\nline two')"
  mk_issue 7 chatgpt-bot "Findings" $'corr: abc\nline two' > "$FORGE_ROOT/issue-7.json"
  run_plane "$home" poll >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "the poll before the read must succeed"
  out=$(run_plane "$home" read 7 2>&1) || rc=$?
  expect_code 0 "$rc" "read of a live issue must succeed"
  assert_contains "$out" "issue: own/mailbox#7" "read names the mailbox issue"
  assert_contains "$out" "from: chatgpt-bot" "read prints the authenticated principal's login"
  assert_contains "$out" "subject: Findings" "read prints the subject"
  assert_contains "$out" "corr: abc" "read prints the body verbatim"
  pass "fm-forge-mail: read prints the principal, subject, and body"
}

test_read_digest_lists_open_mail() {
  local home out rc=0
  home=$(make_home readdigest)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 8 hermes "Second" "hello")" "$(mk_issue 7 chatgpt-bot "Findings" "body")"
  out=$(run_plane "$home" read 2>&1) || rc=$?
  expect_code 0 "$rc" "digest read must succeed"
  assert_contains "$out" "#7  chatgpt-bot  Findings" "the digest lists number, principal, and subject"
  assert_contains "$out" "#8  hermes  Second" "the digest lists every open message"
  pass "fm-forge-mail: a bare read digests the open mailbox"
}

test_read_falls_back_to_the_poll_time_stash_offline() {
  local home out rc=0
  home=$(make_home readoffline)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 7 chatgpt-bot "Findings" "offline body")"
  run_plane "$home" poll >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "the poll that stashes must succeed"
  out=$(FM_FAKE_CURL_FAIL=1 run_plane "$home" read 7 2>&1) || rc=$?
  expect_code 0 "$rc" "an offline read of a stashed issue succeeds"
  assert_contains "$out" "poll-time stash" "the offline read names its stash source"
  assert_contains "$out" "from: chatgpt-bot" "the stashed principal still prints"
  out=$(FM_FAKE_CURL_FAIL=1 run_plane "$home" read 9 2>&1) || rc=$?
  expect_code 1 "$rc" "an offline read with no stash fails"
  assert_contains "$out" "no poll-time stash" "the failure names the missing stash"
  pass "fm-forge-mail: offline handling reads the poll-time stash"
}

test_ack_posts_receipt_then_closes() {
  local home out rc=0 bodies first_close comment_line
  home=$(make_home acknote)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 7 chatgpt-bot "Findings" "body")"
  run_plane "$home" poll >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "the poll before the ack must succeed"
  assert_present "$home/state/forge-mail-inbox/7.json" "the stash exists before the ack"
  : > "$FORGE_ROOT/ack-bodies.log"
  out=$(FM_FAKE_CURL_BODIES="$FORGE_ROOT/ack-bodies.log" \
    run_plane "$home" ack 7 --note "receipt: triaged" 2>&1) || rc=$?
  expect_code 0 "$rc" "ack with a note must succeed"
  assert_contains "$out" "acked: own/mailbox#7 closed" "ack reports the close"
  bodies=$(cat "$FORGE_ROOT/ack-bodies.log")
  assert_contains "$bodies" '{"body":"receipt: triaged"}' "the receipt comment body is the note alone"
  assert_contains "$bodies" '{"state":"closed"}' "the close body sets state closed"
  # Comment first, close second: the receipt lands on the open issue.
  first_close=$(grep -n '{"state":"closed"}' "$FORGE_ROOT/ack-bodies.log" | cut -d: -f1 | sed -n '1p')
  comment_line=$(grep -n 'receipt: triaged' "$FORGE_ROOT/ack-bodies.log" | cut -d: -f1 | sed -n '1p')
  [ "$comment_line" -lt "$first_close" ] || fail "the receipt comment must precede the close"
  assert_contains "$(cat "$home/state/.forge-mail-seen")" "7" "ack records the number locally"
  assert_absent "$home/state/forge-mail-inbox/7.json" "ack removes the stash"
  pass "fm-forge-mail: ack posts the receipt comment then closes, and cleans up"
}

test_ack_without_note_only_closes() {
  local home out rc=0
  home=$(make_home ackplain)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 7 chatgpt-bot "Findings" "body")"
  run_plane "$home" poll >/dev/null 2>&1 || rc=$?
  rm -f "$FORGE_ROOT/curl.log"
  out=$(FM_FAKE_CURL_BODIES="$FORGE_ROOT/plain-bodies.log" \
    run_plane "$home" ack 7 2>&1) || rc=$?
  expect_code 0 "$rc" "ack without a note must succeed"
  assert_equals '{"state":"closed"}' "$(cat "$FORGE_ROOT/plain-bodies.log")" "a plain ack sends only the close"
  assert_not_contains "$(cat "$FORGE_ROOT/curl.log")" " -X POST " "no comment is posted without --note"
  pass "fm-forge-mail: ack without a note closes without commenting"
}

test_ack_aborts_when_the_receipt_fails() {
  local home out rc=0
  home=$(make_home ackcommentfail)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 7 chatgpt-bot "Findings" "body")"
  run_plane "$home" poll >/dev/null 2>&1 || rc=$?
  rm -f "$FORGE_ROOT/curl.log"
  out=$(FM_FAKE_CURL_COMMENT_CODE=500 run_plane "$home" ack 7 --note "note" 2>&1) || rc=$?
  expect_code 1 "$rc" "ack must fail when the receipt comment fails"
  assert_contains "$out" "HTTP 500" "the failure names the HTTP result"
  assert_not_contains "$(cat "$FORGE_ROOT/curl.log")" " -X PATCH " "the close is never attempted after a failed receipt"
  pass "fm-forge-mail: a failed receipt aborts the ack before closing"
}

test_ack_aborts_when_the_close_is_unverified() {
  local home out rc=0
  home=$(make_home ackclosefail)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 7 chatgpt-bot "Findings" "body")"
  run_plane "$home" poll >/dev/null 2>&1 || rc=$?
  out=$(FM_FAKE_CURL_CLOSE_STATE=open run_plane "$home" ack 7 2>&1) || rc=$?
  expect_code 1 "$rc" "ack must fail when the issue does not report closed"
  assert_contains "$out" "did not report closed" "the failure names the unverified state"
  pass "fm-forge-mail: an unverified close fails the ack instead of claiming it"
}

test_ack_accepts_201_from_comment_and_close() {
  # Forgejo answers the receipt POST with 201 (Created) and may answer the
  # close PATCH with 201 too; both are success, not failure.
  local home out rc=0
  home=$(make_home ack201)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 7 chatgpt-bot "Findings" "body")"
  run_plane "$home" poll >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "the poll before the ack must succeed"
  out=$(FM_FAKE_CURL_COMMENT_CODE=201 FM_FAKE_CURL_CLOSE_CODE=201 \
    FM_FAKE_CURL_BODIES="$FORGE_ROOT/ack201-bodies.log" \
    run_plane "$home" ack 7 --note "receipt: triaged" 2>&1) || rc=$?
  expect_code 0 "$rc" "ack must succeed on 201 from both calls"
  assert_contains "$out" "acked: own/mailbox#7 closed" "ack reports the close"
  assert_not_contains "$out" "failed with HTTP" "no failure line is printed for a 201"
  assert_contains "$(cat "$FORGE_ROOT/ack201-bodies.log")" '{"body":"receipt: triaged"}' "the receipt was posted"
  assert_contains "$(cat "$FORGE_ROOT/ack201-bodies.log")" '{"state":"closed"}' "the close was sent"
  assert_contains "$(cat "$home/state/.forge-mail-seen")" "7" "ack records the number locally"
  pass "fm-forge-mail: ack accepts HTTP 201 success from the comment POST and close PATCH"
}

test_ack_refuses_a_recreated_repo() {
  # The wake named number 12 under generation 70001; the repo was deleted
  # and recreated as 80002 with a new #12 before any post-recreation poll
  # ran. ack must refuse rather than comment or close the recreated repo's
  # unrelated message.
  local home out rc=0
  home=$(make_home ackgen)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 12 sender "Original" "first body")"
  run_plane "$home" poll >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "the poll before the recreation must succeed"
  write_repo 80002
  set_issues "$(mk_issue 12 stranger "Recreated" "second body")"
  rm -f "$FORGE_ROOT/curl.log"
  : > "$FORGE_ROOT/ackgen-bodies.log"
  out=$(FM_FAKE_CURL_BODIES="$FORGE_ROOT/ackgen-bodies.log" \
    run_plane "$home" ack 12 --note "receipt" 2>&1) || rc=$?
  expect_code 1 "$rc" "ack must refuse when the forge generation differs"
  assert_contains "$out" "recreated" "the refusal names the generation change"
  assert_not_contains "$(cat "$FORGE_ROOT/curl.log")" " -X POST " "no receipt comment is attempted"
  assert_not_contains "$(cat "$FORGE_ROOT/curl.log")" " -X PATCH " "no close is attempted"
  assert_equals "" "$(cat "$FORGE_ROOT/ackgen-bodies.log")" "no request body is sent"
  assert_present "$home/state/forge-mail-inbox/12.json" "the refused ack keeps the stash"
  rc=0
  out=$(run_plane "$home" poll 2>&1) || rc=$?
  expect_code 0 "$rc" "the post-recreation poll must succeed"
  assert_contains "$out" "woke for own/mailbox#12" "the recreated repo's number 12 wakes again"
  rc=0
  out=$(run_plane "$home" ack 12 2>&1) || rc=$?
  expect_code 0 "$rc" "ack proceeds once the cursor holds the new generation"
  assert_contains "$out" "acked: own/mailbox#12 closed" "the message closes under the new generation"
  pass "fm-forge-mail: ack refuses a recreated repo and proceeds after the poll adopts it"
}

test_ack_proceeds_without_a_stored_generation() {
  # An ack with no prior poll has no stored generation to compare, so the
  # close proceeds: there is no prior generation the number could misname.
  local home out rc=0
  home=$(make_home acknopoll)
  make_fake_tools
  write_repo 70001
  set_issues "$(mk_issue 7 sender "First" "body")"
  out=$(run_plane "$home" ack 7 2>&1) || rc=$?
  expect_code 0 "$rc" "ack with no stored generation proceeds"
  assert_contains "$out" "acked: own/mailbox#7 closed" "the close still lands"
  pass "fm-forge-mail: an ack with no stored generation is not refused"
}

test_help_and_usage_plumbing() {
  local home out rc=0
  home=$(make_home usage)
  out=$(run_plane "$home" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "poll" "--help lists the poll subcommand"
  assert_contains "$out" "read" "--help lists the read subcommand"
  assert_contains "$out" "ack" "--help lists the ack subcommand"
  assert_contains "$out" "status" "--help lists the status subcommand"
  out=$(run_plane "$home" bogus 2>&1) || rc=$?
  expect_code 1 "$rc" "an unknown subcommand must exit 1"
  assert_contains "$out" "poll" "the usage text is printed"
  out=$(run_plane "$home" read notanumber 2>&1) || rc=$?
  expect_code 1 "$rc" "a non-numeric read target must exit 1"
  out=$(run_plane "$home" ack 2>&1) || rc=$?
  expect_code 1 "$rc" "ack without a number must exit 1"
  pass "fm-forge-mail: help and usage plumbing"
}

make_fake_tools

test_unconfigured_poll_is_a_hard_noop
test_partial_configuration_is_still_off
test_env_overrides_env_file
test_status_touches_no_network_or_credentials
test_invalid_host_and_repo_are_rejected
test_missing_drain_token_fails_naming_the_slot
test_drain_token_uses_the_dedicated_slot
test_token_never_reaches_curl_argv
test_poll_wakes_each_new_issue_once_and_only_reads
test_poll_cap_bounds_wakes_per_run
test_poll_cap_defaults_to_ten
test_poll_resurfaces_number_after_generation_reset
test_poll_stale_journal_cannot_suppress_after_reset
test_poll_journal_failure_never_cursor_records
test_poll_journal_recovers_wake_after_drain_ack
test_poll_heals_queued_wake_without_records
test_poll_fail_closed_row_is_kept_for_healing
test_poll_network_failure_fails_closed_and_releases_the_lock
test_read_prints_principal_and_body
test_read_digest_lists_open_mail
test_read_falls_back_to_the_poll_time_stash_offline
test_ack_posts_receipt_then_closes
test_ack_without_note_only_closes
test_ack_aborts_when_the_receipt_fails
test_ack_aborts_when_the_close_is_unverified
test_ack_accepts_201_from_comment_and_close
test_ack_refuses_a_recreated_repo
test_ack_proceeds_without_a_stored_generation
test_help_and_usage_plumbing
