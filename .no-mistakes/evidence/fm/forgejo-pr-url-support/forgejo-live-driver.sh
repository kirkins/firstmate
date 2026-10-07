#!/usr/bin/env bash
# Live driver: runs inside `unshare -Urn` so the disposable Forgejo stand-in
# can serve real HTTPS on 127.0.0.1:443 under host "localhost".
set -u
WORK=$1
WTROOT=$2
BASETREE=$3
HOME_DIR="$WORK/homes/main"
TRANS="$WORK/transcript.txt"
: > "$TRANS"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1" >> "$TRANS"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1" >> "$TRANS"; }
assert_rc() {
  local want=$1 got=$2 msg=$3
  if [ "$want" = "$got" ]; then ok "$msg (rc=$got)"; else bad "$msg: expected rc=$want got=$got"; fi
}
assert_file_has() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3: missing '$2' in $1"; fi
}
assert_file_lacks() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3: unexpected '$2' in $1"; else ok "$3"; fi
}
assert_exists() { if [ -e "$1" ]; then ok "$2"; else bad "$2: missing $1"; fi; }
assert_absent()  { if [ ! -e "$1" ]; then ok "$2"; else bad "$2: unexpectedly exists $1"; fi; }
assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3: '$1' != '$2'"; fi
}

section() { printf '\n===== %s =====\n' "$1" >> "$TRANS"; }

# The product invocation: real scripts from a real tree, isolated env, real
# curl/jq/git and the same real tasks-axi the repo's own suites run against
# fixture homes (markdown backend, local fixture backlog), PATH-fronted
# keyring stub, TLS trust pinned to the fixture CA.
product() {  # <tree> <script> [args...]
  local tree=$1 script=$2; shift 2
  env -i \
    PATH="$WORK/fakebin:/home/kirkins/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$WORK/user-home" \
    SSL_CERT_FILE="$WORK/certs/cert.pem" \
    FM_ROOT_OVERRIDE="$tree" \
    FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    bash "$script" "$@"
}

run_case() {  # <name> <tree> <script> [args...] -> sets CASE_RC
  local name=$1 tree=$2 script=$3; shift 3
  printf '\n$ [tree=%s] %s %s\n' "${tree##*/}" "${script##*/}" "$*" >> "$TRANS"
  product "$tree" "$script" "$@" > "$WORK/out/$name.out" 2> "$WORK/out/$name.err"
  CASE_RC=$?
  sed 's/^/  out| /' "$WORK/out/$name.out" >> "$TRANS"
  sed 's/^/  err| /' "$WORK/out/$name.err" >> "$TRANS"
  printf '  rc=%s\n' "$CASE_RC" >> "$TRANS"
}

mkdir -p "$WORK/out"

# --- namespace + server ------------------------------------------------------
/usr/bin/ip link set lo up || { echo "could not bring up loopback" >> "$TRANS"; exit 90; }
FM_LIVE_WORK="$WORK" PATH="/usr/local/bin:/usr/bin:/bin" \
  python3 /tmp/for-server.py > "$WORK/instance/server.stdout" 2> "$WORK/instance/server.stderr" &
SERVER_PID=$!
for _ in $(seq 1 100); do
  [ -e "$WORK/instance/ready" ] && break
  sleep 0.1
done
[ -e "$WORK/instance/ready" ] || { echo "server never became ready" >> "$TRANS"; kill "$SERVER_PID" 2>/dev/null; exit 91; }
printf 'live Forgejo stand-in serving https://localhost/api/v1 (pid %s)\n' "$SERVER_PID" >> "$TRANS"

# Preflight: real curl over real TLS with the fixture token via a header file,
# so the sampler below never sees the token in any argv.
printf 'Authorization: token %s\n' "$(cat "$WORK/instance/token")" > "$WORK/instance/preflight.hdr"
if curl -sS --cacert "$WORK/certs/cert.pem" -H @"$WORK/instance/preflight.hdr" \
     https://localhost/api/v1/repos/owner/repo/pulls/9 > "$WORK/out/preflight.json" 2>"$WORK/out/preflight.err"; then
  ok "preflight real-TLS REST read against the stand-in"
else
  bad "preflight REST read failed: $(cat "$WORK/out/preflight.err")"
fi
rm -f "$WORK/instance/preflight.hdr"

# argv sampler: proves curl processes were observable and the token bytes
# never appeared in any process argument list during the whole run. The token
# pattern is read from a file (grep -f) so the sampler's own argv never
# carries it and cannot self-match.
: > "$WORK/instance/argv-token-hits"
: > "$WORK/instance/argv-curl-sightings"
(
  while [ ! -e "$WORK/instance/stop-sampler" ]; do
    ps -eo args= 2>/dev/null | grep -v '^grep' | grep -F -- 'curl -sS' >> "$WORK/instance/argv-curl-sightings" || true
    ps -eo args= 2>/dev/null | grep -F -f "$WORK/instance/token" >> "$WORK/instance/argv-token-hits" || true
  done
) &
SAMPLER_PID=$!

URL=https://localhost/owner/repo/pulls/9

# --- S0: old-failure reproduction on the base commit -------------------------
section "S0 old-failure reproduction (base commit 70f2ed3d)"
run_case s0-check-base "$BASETREE" "$BASETREE/bin/fm-pr-check.sh" task-x1 "$URL"
assert_rc 2 "$CASE_RC" "S0 base fm-pr-check.sh refuses the Forgejo URL"
assert_file_has "$WORK/out/s0-check-base.err" "error: invalid PR check request" "S0 base check names the invalid PR check request"
run_case s0-merge-base "$BASETREE" "$BASETREE/bin/fm-pr-merge.sh" task-x1 "$URL"
assert_rc 2 "$CASE_RC" "S0 base fm-pr-merge.sh refuses the Forgejo URL"
assert_file_has "$WORK/out/s0-merge-base.err" "error: invalid PR merge request" "S0 base merge names the invalid PR merge request"
assert_absent "$HOME_DIR/state/task-x1.check.sh" "S0 base run armed nothing"
assert_file_lacks "$HOME_DIR/state/task-x1.meta" "pr=$URL" "S0 base run recorded no pr="

# --- S1: check records and arms the Forgejo watch -----------------------------
section "S1 fm-pr-check.sh records and arms (task-x1, PR 9)"
printf 'registered project origin: %s\n' "$(git -C "$WORK/project" remote get-url origin)" >> "$TRANS"
run_case s1-check "$WTROOT" "$WTROOT/bin/fm-pr-check.sh" task-x1 "$URL"
assert_rc 0 "$CASE_RC" "S1 fm-pr-check.sh accepts the Forgejo pull request URL"
assert_file_has "$WORK/out/s1-check.out" "armed: state/task-x1.check.sh" "S1 check reports the armed poll"
assert_file_has "$HOME_DIR/state/task-x1.meta" "pr=$URL" "S1 meta records pr="
assert_file_has "$HOME_DIR/state/task-x1.meta" "pr_head=1111111111111111111111111111111111111111" "S1 meta records the REST-reported pr_head"
assert_exists "$HOME_DIR/state/task-x1.pr-poll" "S1 poll sidecar published"
assert_eq "$(printf '%s\n%s\n%s\n%s\n%s' forgejo "$URL" localhost owner/repo 9)" \
  "$(cat "$HOME_DIR/state/task-x1.pr-poll")" "S1 sidecar carries the provider-tagged identity"
cmp -s "$WTROOT/bin/fm-pr-poll.sh" "$HOME_DIR/state/task-x1.check.sh" \
  && ok "S1 armed watcher is byte-identical to bin/fm-pr-poll.sh" \
  || bad "S1 armed watcher differs from bin/fm-pr-poll.sh"
assert_file_has "$WORK/instance/request.log" '"path": "/api/v1/repos/owner/repo/pulls/9"' "S1 live REST read of the pull request"
assert_file_has "$WORK/instance/request.log" '"auth": "bearer-ok"' "S1 REST read carried the host-keyed keyring token"
assert_file_has "$WORK/instance/secret-tool.log" "secret-tool lookup service localhost/forgejo-cli/omarchy" "S1 token came from the host-keyed keyring slot"

# --- S2: draft refusal --------------------------------------------------------
section "S2 draft pull request is refused (task-x2, PR 10)"
run_case s2-draft "$WTROOT" "$WTROOT/bin/fm-pr-check.sh" task-x2 https://localhost/owner/repo/pulls/10
assert_rc 1 "$CASE_RC" "S2 draft PR refuses the check"
assert_file_has "$WORK/out/s2-draft.err" "is a draft pull request" "S2 refusal names the draft state"
assert_file_has "$WORK/out/s2-draft.err" "mark it ready for review" "S2 refusal names the remedy"
assert_file_lacks "$HOME_DIR/state/task-x2.meta" "pr=https://localhost/owner/repo/pulls/10" "S2 recorded no pr="
assert_absent "$HOME_DIR/state/task-x2.check.sh" "S2 armed no poll"

# --- S3: binding mismatch refusal ---------------------------------------------
section "S3 project-binding mismatch is refused (task-x3, PR 11)"
run_case s3-mismatch "$WTROOT" "$WTROOT/bin/fm-pr-check.sh" task-x3 https://localhost/owner/repo/pulls/11
assert_rc 1 "$CASE_RC" "S3 unbound repository refuses the check"
assert_file_has "$WORK/out/s3-mismatch.err" "refusing to record" "S3 refusal is loud"
assert_file_has "$WORK/out/s3-mismatch.err" "owner/other" "S3 refusal names the project's own binding"
assert_file_lacks "$HOME_DIR/state/task-x3.meta" "pr=https://localhost/owner/repo/pulls/11" "S3 recorded no pr="
assert_absent "$HOME_DIR/state/task-x3.check.sh" "S3 armed no poll"

# --- S4: the armed poll wakes only on an explicit merged reading ---------------
section "S4 armed poll stays silent until merged (task-x1, PR 9)"
run_case s4-poll-open "$WTROOT" "$HOME_DIR/state/task-x1.check.sh"
assert_rc 0 "$CASE_RC" "S4 poll on an open PR exits 0"
[ ! -s "$WORK/out/s4-poll-open.out" ] \
  && ok "S4 poll printed nothing while the PR is open" \
  || bad "S4 poll spoke on an open PR: $(cat "$WORK/out/s4-poll-open.out")"
python3 - "$WORK/instance/prs/9.json" <<'PY'
import json, sys
p = sys.argv[1]
pr = json.load(open(p))
pr["merged"] = True
pr["state"] = "closed"
json.dump(pr, open(p, "w"))
PY
run_case s4-poll-merged "$WTROOT" "$HOME_DIR/state/task-x1.check.sh"
assert_rc 0 "$CASE_RC" "S4 poll on a merged PR exits 0"
assert_eq merged "$(cat "$WORK/out/s4-poll-open.out" 2>/dev/null; cat "$WORK/out/s4-poll-merged.out")" "S4 poll emits exactly one merged line only after the merged reading"
python3 - "$WORK/instance/prs/9.json" <<'PY'
import json, sys
p = sys.argv[1]
pr = json.load(open(p))
pr["merged"] = False
pr["state"] = "open"
json.dump(pr, open(p, "w"))
PY

# --- S5: guarded merge through the live REST path ------------------------------
section "S5 fm-pr-merge.sh merges a green PR (task-x4, PR 12)"
MURL=https://localhost/owner/repo/pulls/12
run_case s5-arm "$WTROOT" "$WTROOT/bin/fm-pr-check.sh" task-x4 "$MURL"
assert_rc 0 "$CASE_RC" "S5 check arms the merge-bound task first"
REQUESTS_BEFORE_MERGE=$(grep -c '"method": "POST"' "$WORK/instance/request.log" || true)
run_case s5-merge "$WTROOT" "$WTROOT/bin/fm-pr-merge.sh" task-x4 "$MURL"
assert_rc 0 "$CASE_RC" "S5 fm-pr-merge.sh merges the Forgejo pull request"
assert_file_has "$WORK/out/s5-merge.err" "verified: $MURL is open and mergeable, with a successful combined commit status at head 4444444444444444444444444444444444444444" "S5 merge reports the verified pre-state"
assert_file_has "$WORK/out/s5-merge.out" "verified: $MURL is merged" "S5 merge reports the confirmed landed state"
assert_file_has "$HOME_DIR/state/.wake-queue" "$MURL" "S5 merge left a durable landed record naming the PR"
assert_exists "$HOME_DIR/state/task-x4.merge-authority" "S5 merge persisted its authority record"
assert_file_has "$HOME_DIR/state/task-x4.merge-authority" "attended" "S5 authority record says attended"
assert_file_has "$WORK/instance/merge-events.log" '"style": "squash"' "S5 instance accepted a squash merge"
POSTS_AFTER_MERGE=$(grep -c '"method": "POST"' "$WORK/instance/request.log" || true)
assert_eq $((REQUESTS_BEFORE_MERGE + 1)) "$POSTS_AFTER_MERGE" "S5 exactly one merge POST reached the instance"
assert_file_has "$WORK/instance/request.log" '"path": "/api/v1/repos/owner/repo/pulls/12/merge"' "S5 merge POST addressed the URL's own endpoint"
grep '"method": "POST"' "$WORK/instance/request.log" | grep -qF '"body": "{\"Do\":\"squash\"}"' \
  && ok "S5 merge POST carried the squash style in its body" \
  || bad "S5 merge POST body was not the squash style: $(grep '"method": "POST"' "$WORK/instance/request.log")"
assert_file_has "$HOME_DIR/state/task-x4.meta" "pr=$MURL" "S5 merge re-recorded pr= metadata"
assert_exists "$HOME_DIR/state/task-x4.check.sh" "S5 merge poll remains armed"
python3 -c 'import json,sys; pr=json.load(open(sys.argv[1])); sys.exit(0 if pr["merged"] is True and pr["state"]=="closed" else 1)' \
  "$WORK/instance/prs/12.json" \
  && ok "S5 instance state flipped PR 12 to merged" \
  || bad "S5 instance state did not flip PR 12 to merged"

# --- S6: red combined status refuses -------------------------------------------
section "S6 red combined commit status refuses the merge (task-x5, PR 13)"
RURL=https://localhost/owner/repo/pulls/13
run_case s6-arm "$WTROOT" "$WTROOT/bin/fm-pr-check.sh" task-x5 "$RURL"
assert_rc 0 "$CASE_RC" "S6 check arms the task first"
REQUESTS_BEFORE_S6=$(grep -c '"method": "POST"' "$WORK/instance/request.log" || true)
run_case s6-merge "$WTROOT" "$WTROOT/bin/fm-pr-merge.sh" task-x5 "$RURL"
assert_rc 1 "$CASE_RC" "S6 red-status merge refuses"
assert_file_has "$WORK/out/s6-merge.err" 'the combined commit status at the head is "failure", not success' "S6 refusal names the red combined status"
POSTS_AFTER_S6=$(grep -c '"method": "POST"' "$WORK/instance/request.log" || true)
assert_eq "$REQUESTS_BEFORE_S6" "$POSTS_AFTER_S6" "S6 no merge POST was sent"

# --- S7: no statuses is not green ----------------------------------------------
section "S7 a head with no statuses is not green (task-x6, PR 14)"
NURL=https://localhost/owner/repo/pulls/14
run_case s7-arm "$WTROOT" "$WTROOT/bin/fm-pr-check.sh" task-x6 "$NURL"
assert_rc 0 "$CASE_RC" "S7 check arms the task first"
REQUESTS_BEFORE_S7=$(grep -c '"method": "POST"' "$WORK/instance/request.log" || true)
run_case s7-merge "$WTROOT" "$WTROOT/bin/fm-pr-merge.sh" task-x6 "$NURL"
assert_rc 1 "$CASE_RC" "S7 no-status merge refuses"
assert_file_has "$WORK/out/s7-merge.err" 'the combined commit status at the head is "none", not success' "S7 refusal reads no checks as none, not green"
POSTS_AFTER_S7=$(grep -c '"method": "POST"' "$WORK/instance/request.log" || true)
assert_eq "$REQUESTS_BEFORE_S7" "$POSTS_AFTER_S7" "S7 no merge POST was sent"

# --- token hygiene --------------------------------------------------------------
section "token hygiene across the whole live run"
TOKEN_HITS=$(grep -c . "$WORK/instance/argv-token-hits" || true)
CURL_SIGHTINGS=$(grep -c . "$WORK/instance/argv-curl-sightings" || true)
assert_eq 0 "$TOKEN_HITS" "the keyring token never appeared in any sampled process argument list"
if [ "$CURL_SIGHTINGS" -gt 0 ]; then
  ok "sampler observed $CURL_SIGHTINGS live curl invocations (sampling was live)"
else
  bad "sampler never observed a curl process, so the token-absence proof is weak"
fi
assert_file_lacks "$WORK/instance/request.log" '"auth": "MISSING"' "every REST request carried the bearer token"

# --- teardown --------------------------------------------------------------------
touch "$WORK/instance/stop-sampler"
wait "$SAMPLER_PID" 2>/dev/null || true
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

printf '\n===== SUMMARY: %s passed, %s failed =====\n' "$PASS" "$FAIL" >> "$TRANS"
cat "$TRANS"
[ "$FAIL" -eq 0 ]
