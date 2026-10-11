#!/usr/bin/env bash
# Live drive of bin/fm-forge-mail.sh + bin/fm-forge-mail-check.sh against a
# disposable local HTTPS forge (real curl, real TLS, real wire, real locks and
# wake queue). Produces a pass/fail transcript plus artifacts.
set -u
ROOT=/home/kirkins/.no-mistakes/worktrees/c3ea402bfbf7/01M4PFB86V31BS62R1X7KDST0K
RIG=/tmp/fm-forge-live
EVID=/home/kirkins/.no-mistakes/evidence/01M4PFB86V31BS62R1X7KDST0K
PLANE="$ROOT/bin/fm-forge-mail.sh"
CHECK="$ROOT/bin/fm-forge-mail-check.sh"
PROXY=http://127.0.0.1:18560
PASS=0 FAIL=0

step() { printf '\n===== %s\n' "$*"; }
ok()   { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }
expect_rc() { # got want label
  if [ "$1" -eq "$2" ]; then ok "$3"; else bad "$3 (want rc=$2, got rc=$1)"; fi
}
contains() { case "$1" in *"$2"*) ok "$3";; *) bad "$3 (missing: $2)";; esac; }
not_contains() { case "$1" in *"$2"*) bad "$3 (unexpectedly found: $2)";; *) ok "$3";; esac; }

plane() { # home args...
  local home=$1; shift
  env FM_HOME="$home" PATH="$RIG/fakebin:$PATH" HTTPS_PROXY="$PROXY" \
    CURL_CA_BUNDLE="$RIG/ca.pem" "$PLANE" "$@"
}
checkrun() { # home args...
  local home=$1; shift
  env FM_HOME="$home" PATH="$RIG/fakebin:$PATH" HTTPS_PROXY="$PROXY" \
    CURL_CA_BUNDLE="$RIG/ca.pem" "$CHECK" "$@"
}
mkhome() { # name [envfile-content]
  local home="$RIG/homes/$1"; rm -rf "$home"; mkdir -p "$home"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" > "$home/.env"; fi
  printf '%s' "$home"
}
mkissue() { # n login title body  -> one JSON object on stdout
  jq -nc --argjson n "$1" --arg login "$2" --arg title "$3" --arg body "$4" \
    '{number:$n,state:"open",title:$title,body:$body,user:{login:$login},labels:[{name:"mail"}]}'
}
reset_forge() { # repo-id  (clears server-side effects and ctl overrides)
  printf '%s' '{"comments":[],"closed":[],"seq":0}' > "$RIG/forge-state.json"
  printf '%s' "$1" > "$RIG/ctl/repo-id"
  rm -f "$RIG/ctl/refuse" "$RIG/ctl/sleep" "$RIG/ctl/close-state" "$RIG/ctl/comment-code" "$RIG/ctl/token-mode"
  printf 0 > "$RIG/ctl/sleep"
}
set_open_issues() { # issue-json...
  jq -s '.' > "$RIG/ctl/issues.json" <<< "$(printf '%s\n' "$@")"
}
marker() { wc -l < "$RIG/requests.log" 2>/dev/null || printf 0; }
since() { # marker -> requests since marker (1-indexed line)
  tail -n +"$(( ${1:-0} + 1 ))" "$RIG/requests.log" 2>/dev/null || true
}
wake_rows() { # home -> count of forge-mail check rows
  local n
  n=$(grep -c $'\tcheck\tforge-mail:' "$1/state/.wake-queue" 2>/dev/null)
  printf '%s' "${n:-0}"
}
state_has() { # jq-expr label
  if jq -e "$1" "$RIG/forge-state.json" >/dev/null 2>&1; then ok "$2"; else bad "$2 (jq: $1)"; fi
}

step "S1: unconfigured home is a hard no-op (off unless .env configures it)"
H=$(mkhome s1-off)
out=$(plane "$H" poll 2>&1); rc=$?
expect_rc "$rc" 0 "S1 unconfigured poll exits 0"
[ -z "$out" ] && ok "S1 unconfigured poll prints nothing at all" || bad "S1 unconfigured poll printed: $out"
out=$(plane "$H" status 2>&1); rc=$?
expect_rc "$rc" 0 "S1 unconfigured status exits 0"
contains "$out" "off" "S1 status names its off state"
contains "$out" "FM_FORGE_MAIL_HOST" "S1 off status names the missing keys"
H=$(mkhome s1-half "FM_FORGE_MAIL_HOST=mailbox.test.forge")
out=$(plane "$H" poll 2>&1); rc=$?
expect_rc "$rc" 0 "S1 half-configured poll stays a silent no-op"
[ -z "$out" ] && ok "S1 half-configured poll prints nothing" || bad "S1 half-configured poll printed: $out"
out=$(plane "$H" read 7 2>&1); rc=$?
expect_rc "$rc" 1 "S1 read on a half-configured home fails"
contains "$out" "FM_FORGE_MAIL_REPO" "S1 read names the missing key"

step "S2: poll surfaces each new mail-labeled open issue once, reads only, stashes the body"
reset_forge 70001
set_open_issues \
  "$(mkissue 13 hermes "Second" "hello")" \
  "$(mkissue 12 chatgpt-bot "Findings" $'corr: abc\nline two')"
H=$(mkhome s2-poll "FM_FORGE_MAIL_HOST=mailbox.test.forge
FM_FORGE_MAIL_REPO=own/mailbox")
M=$(marker)
out=$(plane "$H" poll 2>&1); rc=$?
expect_rc "$rc" 0 "S2 first poll succeeds"
printf '%s\n' "$out" | sed 's/^/  | /'
contains "$out" "woke for own/mailbox#12" "S2 poll wakes issue 12 (oldest first)"
contains "$out" "woke for own/mailbox#13" "S2 poll wakes issue 13"
Q=$(cat "$H/state/.wake-queue" 2>/dev/null || true)
printf '%s\n' "$Q" | sed 's/^/  queue| /'
contains "$Q" "forge-mail:70001/12" "S2 wake key is generation-scoped (repo id)"
contains "$Q" "check: forge-mail own/mailbox#12 - message from chatgpt-bot - Findings" "S2 wake payload names mailbox, number, sender principal, subject"
C=$(cat "$H/state/.forge-mail-seen" 2>/dev/null || true)
contains "$C" "generation=70001" "S2 cursor records the generation key"
contains "$C" "12" "S2 cursor records the surfaced number"
contains "$(cat "$H/state/.forge-mail-woken" 2>/dev/null)" $'70001\t12' "S2 journal records generation+number"
contains "$(cat "$H/state/forge-mail-inbox/12.json" 2>/dev/null)" "corr: abc" "S2 poll stashes the body for offline reading"
LOG=$(since "$M")
printf '%s\n' "$LOG" | sed 's/^/  api| /'
if [ "$(printf '%s\n' "$LOG" | grep -c 'auth=ok')" -ge 1 ]; then ok "S2 every API call authenticated with the drain token over the wire"; else bad "S2 no authenticated calls logged"; fi
not_contains "$LOG" "auth=FAIL" "S2 no unauthenticated call"
not_contains "$LOG" "POST" "S2 poll never writes (no comment)"
not_contains "$LOG" "PATCH" "S2 poll never closes an issue"
out=$(plane "$H" poll 2>&1); rc=$?
expect_rc "$rc" 0 "S2 second poll succeeds"
contains "$out" "no new mail" "S2 re-poll reports no new mail"
expect_rc "$(wake_rows "$H")" 2 "S2 two issues wake exactly once each"

step "S3: read prints the principal, subject, and body; offline falls back to the poll-time stash"
out=$(plane "$H" read 12 2>&1); rc=$?
expect_rc "$rc" 0 "S3 live read of #12 succeeds"
printf '%s\n' "$out" | sed 's/^/  | /'
contains "$out" "issue: own/mailbox#12" "S3 read names the mailbox issue"
contains "$out" "from: chatgpt-bot" "S3 read prints the authenticated principal's login"
contains "$out" "subject: Findings" "S3 read prints the subject"
contains "$out" "corr: abc" "S3 read prints the body verbatim"
out=$(plane "$H" read 2>&1); rc=$?
expect_rc "$rc" 0 "S3 digest read succeeds"
printf '%s\n' "$out" | sed 's/^/  | /'
contains "$out" "#12  chatgpt-bot  Findings" "S3 digest lists number, principal, subject"
contains "$out" "#13  hermes  Second" "S3 digest lists every open message"
printf x > "$RIG/ctl/refuse"
out=$(plane "$H" read 12 2>&1); rc=$?
expect_rc "$rc" 0 "S3 offline read of a stashed issue still succeeds"
printf '%s\n' "$out" | sed 's/^/  | /'
contains "$out" "poll-time stash" "S3 offline read names its stash source"
contains "$out" "from: chatgpt-bot" "S3 stashed principal still prints"
out=$(plane "$H" read 999 2>&1); rc=$?
expect_rc "$rc" 1 "S3 offline read with no stash fails"
contains "$out" "no poll-time stash" "S3 failure names the missing stash"
rm -f "$RIG/ctl/refuse"

step "S4: ack posts the one-line receipt then closes (close-on-ack); the open set shrinks"
M=$(marker)
out=$(plane "$H" ack 12 --note "receipt: triaged" 2>&1); rc=$?
expect_rc "$rc" 0 "S4 ack with a note succeeds"
printf '%s\n' "$out" | sed 's/^/  | /'
contains "$out" "acked: own/mailbox#12 closed" "S4 ack reports the close"
LOG=$(since "$M")
printf '%s\n' "$LOG" | sed 's/^/  api| /'
first_post=$(printf '%s\n' "$LOG" | grep -n "POST .*issues/12/comments" | cut -d: -f1 | sed -n 1p)
first_patch=$(printf '%s\n' "$LOG" | grep -n "PATCH .*issues/12 " | cut -d: -f1 | sed -n 1p)
if [ -n "$first_post" ] && [ -n "$first_patch" ] && [ "$first_post" -lt "$first_patch" ]; then
  ok "S4 the receipt comment is posted before the close"
else
  bad "S4 comment/close order wrong (post=$first_post patch=$first_patch)"
fi
contains "$LOG" 'body={"body": "receipt: triaged"}' "S4 receipt body is the note alone (one line, no secrets)"
state_has '(.comments | length) == 1 and .comments[0].body == "receipt: triaged" and .comments[0].issue == 12' "S4 the forge recorded exactly one receipt comment on #12"
out=$(plane "$H" read 2>&1); rc=$?
expect_rc "$rc" 0 "S4 digest after ack succeeds"
printf '%s\n' "$out" | sed 's/^/  | /'
contains "$out" "#13" "S4 the open set still holds the unacked message"
not_contains "$out" "#12" "S4 the acked message left the live queue (open set == live queue)"
contains "$(cat "$H/state/.forge-mail-seen")" "12" "S4 ack records the number locally"
[ ! -f "$H/state/forge-mail-inbox/12.json" ] && ok "S4 ack removes the stash" || bad "S4 stash survived the ack"
M=$(marker)
out=$(plane "$H" ack 13 2>&1); rc=$?
expect_rc "$rc" 0 "S4 plain ack (no note) succeeds"
LOG=$(since "$M")
printf '%s\n' "$LOG" | sed 's/^/  api| /'
not_contains "$LOG" "POST" "S4 no comment is posted without --note"
contains "$LOG" "PATCH" "S4 the close is still sent"

step "S5 (adversarial): ack refuses a recreated repo, writes nothing, then proceeds once poll adopts the new generation"
reset_forge 70001
set_open_issues "$(mkissue 5 sender "Original" "first body")"
H=$(mkhome s5-ackgen "FM_FORGE_MAIL_HOST=mailbox.test.forge
FM_FORGE_MAIL_REPO=own/mailbox")
out=$(plane "$H" poll 2>&1); rc=$?
expect_rc "$rc" 0 "S5 poll wakes #5 under generation 70001"
contains "$out" "woke for own/mailbox#5" "S5 the wake names #5"
contains "$(cat "$H/state/.wake-queue")" "forge-mail:70001/5" "S5 wake keyed by the original repo id"
# The repo is deleted and recreated: new id, numbering reset, a stranger's new #5.
printf '%s' '{"comments":[],"closed":[],"seq":0}' > "$RIG/forge-state.json"
printf 80002 > "$RIG/ctl/repo-id"
set_open_issues "$(mkissue 5 stranger "Recreated" "second body")"
M=$(marker)
out=$(plane "$H" ack 5 --note "receipt" 2>&1); rc=$?
expect_rc "$rc" 1 "S5 ack refuses when the forge generation differs"
printf '%s\n' "$out" | sed 's/^/  | /'
contains "$out" "recreated" "S5 the refusal names the generation change"
contains "$out" "poll first" "S5 the refusal tells the operator to poll first"
LOG=$(since "$M")
printf '%s\n' "$LOG" | sed 's/^/  api| /'
not_contains "$LOG" "POST" "S5 no receipt comment touches the recreated repo"
not_contains "$LOG" "PATCH" "S5 no close touches the recreated repo"
state_has '(.comments | length) == 0' "S5 the forge state holds no receipt from the refused ack"
state_has '(.closed | index(5)) == null' "S5 the stranger's #5 was never closed"
[ -f "$H/state/forge-mail-inbox/5.json" ] && ok "S5 the refused ack keeps the stash" || bad "S5 stash lost on refusal"
out=$(plane "$H" poll 2>&1); rc=$?
expect_rc "$rc" 0 "S5 post-recreation poll succeeds"
contains "$out" "woke for own/mailbox#5" "S5 the recreated repo's reused #5 wakes again"
contains "$(cat "$H/state/.wake-queue")" "forge-mail:80002/5" "S5 the new wake is keyed by the new generation"
M=$(marker)
out=$(plane "$H" ack 5 2>&1); rc=$?
expect_rc "$rc" 0 "S5 ack proceeds once the cursor holds the new generation"
contains "$out" "acked: own/mailbox#5 closed" "S5 the message closes under the new generation"
state_has '(.closed | index(5)) != null' "S5 the forge recorded the close"
H=$(mkhome s5-nopoll "FM_FORGE_MAIL_HOST=mailbox.test.forge
FM_FORGE_MAIL_REPO=own/mailbox")
reset_forge 70001
set_open_issues "$(mkissue 7 sender "First" "body")"
out=$(plane "$H" ack 7 2>&1); rc=$?
expect_rc "$rc" 0 "S5 ack with no stored generation (no prior poll) proceeds"
contains "$out" "acked: own/mailbox#7 closed" "S5 the close lands with no prior generation to compare"

step "S6: a repo recreation resets numbering without suppressing reused numbers; stale evidence is cleared"
reset_forge 70001
set_open_issues "$(mkissue 5 sender "Original" "first body")"
H=$(mkhome s6-genreset "FM_FORGE_MAIL_HOST=mailbox.test.forge
FM_FORGE_MAIL_REPO=own/mailbox")
plane "$H" poll >/dev/null 2>&1
# Seed stale prior-generation evidence plus a stale stash.
printf '70001\t9\n' >> "$H/state/.forge-mail-woken"
printf '{"number":4,"stale":true}\n' > "$H/state/forge-mail-inbox/4.json"
printf '%s' '{"comments":[],"closed":[],"seq":0}' > "$RIG/forge-state.json"
printf 80002 > "$RIG/ctl/repo-id"
set_open_issues "$(mkissue 5 sender "Recreated" "second body")"
out=$(plane "$H" poll 2>&1); rc=$?
expect_rc "$rc" 0 "S6 second-generation poll succeeds"
contains "$out" "woke for own/mailbox#5" "S6 a reused number wakes again under the new repo id"
contains "$(cat "$H/state/.wake-queue")" "forge-mail:80002/5" "S6 the new wake is keyed by the new generation"
contains "$(sed -n 1p "$H/state/.forge-mail-seen")" "generation=80002" "S6 the cursor carries the new generation"
not_contains "$(cat "$H/state/.forge-mail-woken")" "70001" "S6 stale prior-generation journal evidence is cleared"
[ ! -f "$H/state/forge-mail-inbox/4.json" ] && ok "S6 old-generation stashes are pruned" || bad "S6 stale stash survived the reset"

step "S7: the per-poll wake cap bounds a flood (default 10); the remainder surfaces on the next poll"
reset_forge 70001
issues=(); i=12; while [ "$i" -ge 1 ]; do issues+=("$(mkissue "$i" flood "Msg $i" body)"); i=$((i-1)); done
set_open_issues "${issues[@]}"
H=$(mkhome s7-cap "FM_FORGE_MAIL_HOST=mailbox.test.forge
FM_FORGE_MAIL_REPO=own/mailbox")
out=$(plane "$H" poll 2>&1); rc=$?
expect_rc "$rc" 0 "S7 capped poll succeeds"
contains "$out" "per-poll wake cap (10) reached" "S7 the default cap of ten is reported"
expect_rc "$(wake_rows "$H")" 10 "S7 one poll wakes at most ten messages"
contains "$out" "woke for own/mailbox#1" "S7 the oldest messages surface first under the cap"
not_contains "$out" "woke for own/mailbox#11" "S7 the capped tail does not surface yet"
out=$(plane "$H" poll 2>&1); rc=$?
expect_rc "$rc" 0 "S7 follow-up poll succeeds"
contains "$out" "woke for own/mailbox#11" "S7 the capped remainder surfaces on the next poll"
expect_rc "$(wake_rows "$H")" 12 "S7 all twelve issues surface across two polls (none dropped)"

step "S8: the drain token comes only from its dedicated keyring slot and never reaches curl's argv"
reset_forge 70001
set_open_issues "$(mkissue 7 sender "First" "body")"
H=$(mkhome s8-token "FM_FORGE_MAIL_HOST=mailbox.test.forge
FM_FORGE_MAIL_REPO=own/mailbox")
printf other > "$RIG/ctl/token-mode"
out=$(plane "$H" poll 2>&1); rc=$?
expect_rc "$rc" 1 "S8 a different keyring slot answering must not satisfy the plane"
contains "$out" "forgejo-mail/drain" "S8 the failure names the dedicated slot"
expect_rc "$(wake_rows "$H")" 0 "S8 nothing is woken with the wrong slot"
printf empty > "$RIG/ctl/token-mode"
out=$(plane "$H" poll 2>&1); rc=$?
expect_rc "$rc" 1 "S8 an empty slot fails the poll"
contains "$out" "forgejo-mail/drain" "S8 the empty-slot failure names the slot"
rm -f "$RIG/ctl/token-mode"
out=$(plane "$H" poll 2>&1); rc=$?
expect_rc "$rc" 0 "S8 the dedicated slot's token works"
contains "$out" "woke for own/mailbox#7" "S8 the message surfaces with the dedicated token"
grep -q "mailbox.test.forge/forgejo-mail/drain" "$RIG/secrettool.log" \
  && ok "S8 the drain slot is the one looked up" || bad "S8 drain slot never looked up"
if grep -qF "faketoken0123456789abcdef" "$RIG/curl-argv.log"; then
  bad "S8 the token leaked into a curl argument list"
else
  ok "S8 the token never appears in any curl argv"
fi
if grep -q "auth=FAIL" "$RIG/requests.log"; then
  bad "S8 some API call arrived unauthenticated"
else
  ok "S8 every authenticated call carried the token header over the wire"
fi

step "S9: arm/disarm the standing check; the arm probe judges the home's .env, not the caller's environment"
reset_forge 70001
set_open_issues "$(mkissue 20 sender "Standing" "wake me")"
H=$(mkhome s9-arm "FM_FORGE_MAIL_HOST=mailbox.test.forge
FM_FORGE_MAIL_REPO=own/mailbox")
out=$(env FM_HOME="$H" PATH="$RIG/fakebin:$PATH" HTTPS_PROXY="$PROXY" CURL_CA_BUNDLE="$RIG/ca.pem" "$CHECK" arm 2>&1); rc=$?
expect_rc "$rc" 0 "S9 arm succeeds on a configured home"
printf '%s\n' "$out" | sed 's/^/  | /'
contains "$out" "armed: state/forge-mail.check.sh" "S9 arm names the shim it wrote"
[ -x "$H/state/forge-mail.check.sh" ] && ok "S9 the check shim exists and is executable" || bad "S9 shim missing"
[ -f "$H/state/forge-mail.check-trust" ] && ok "S9 the trust binding exists for the watcher" || bad "S9 trust binding missing"
contains "$(cat "$H/state/forge-mail.check.sh")" "fm-forge-mail-check.sh check" "S9 the shim dispatches the check action"
contains "$(cat "$H/state/forge-mail.check.sh")" "FM_HOME=$H" "S9 the shim pins the absolute home"
out=$(env FM_HOME="$H" PATH="$RIG/fakebin:$PATH" HTTPS_PROXY="$PROXY" CURL_CA_BUNDLE="$RIG/ca.pem" "$CHECK" arm 2>&1); rc=$?
expect_rc "$rc" 0 "S9 re-arm is idempotent"
# Dispatch exactly the way the watcher does: execute the shim itself.
out=$(env -u FM_HOME PATH="$RIG/fakebin:$PATH" HTTPS_PROXY="$PROXY" CURL_CA_BUNDLE="$RIG/ca.pem" \
  "$H/state/forge-mail.check.sh" 2>&1); rc=$?
expect_rc "$rc" 0 "S9 the armed shim runs cleanly as the watcher would run it"
printf '%s\n' "$out" | sed 's/^/  | /'
contains "$out" "forge-mail: new mail: woke for own/mailbox#20" "S9 the armed shim doorbells one line for new mail"
contains "$(cat "$H/state/.wake-queue")" "forge-mail:70001/20" "S9 the shim's poll queued the durable wake"
out=$(env FM_HOME="$H" PATH="$RIG/fakebin:$PATH" HTTPS_PROXY="$PROXY" CURL_CA_BUNDLE="$RIG/ca.pem" "$CHECK" disarm 2>&1); rc=$?
expect_rc "$rc" 0 "S9 disarm succeeds"
[ ! -e "$H/state/forge-mail.check.sh" ] && ok "S9 disarm removes the shim" || bad "S9 shim survived disarm"
[ ! -e "$H/state/forge-mail.check-trust" ] && ok "S9 disarm removes the trust binding" || bad "S9 trust survived disarm"
# The env-scrub guard: caller exports the two keys (documented direct-invocation
# workflow) but the home's .env lacks them.
H=$(mkhome s9-envonly)
out=$(env FM_FORGE_MAIL_HOST=mailbox.test.forge FM_FORGE_MAIL_REPO=own/mailbox \
  FM_HOME="$H" PATH="$RIG/fakebin:$PATH" HTTPS_PROXY="$PROXY" CURL_CA_BUNDLE="$RIG/ca.pem" \
  "$CHECK" arm 2>&1); rc=$?
expect_rc "$rc" 1 "S9 arming is refused when only the caller's environment configures the plane"
printf '%s\n' "$out" | sed 's/^/  | /'
contains "$out" "FM_FORGE_MAIL_HOST" "S9 the refusal names the missing key"
contains "$out" ".env" "S9 the refusal points at the home's .env"
[ ! -e "$H/state/forge-mail.check.sh" ] && ok "S9 no shim is written for an env-only home" || bad "S9 shim written for env-only home"
[ ! -e "$H/state/forge-mail.check-trust" ] && ok "S9 no trust binding is written for an env-only home" || bad "S9 trust written for env-only home"
H=$(mkhome s9-bare)
out=$(env FM_HOME="$H" PATH="$RIG/fakebin:$PATH" HTTPS_PROXY="$PROXY" CURL_CA_BUNDLE="$RIG/ca.pem" "$CHECK" arm 2>&1); rc=$?
expect_rc "$rc" 1 "S9 arming a fully unconfigured home is refused"

step "S10: the standing check reports new mail once, stays silent on proven no-ops, and always doorbells a timeout"
reset_forge 70001
set_open_issues "$(mkissue 7 sender "First" "body")"
H=$(mkhome s10-check "FM_FORGE_MAIL_HOST=mailbox.test.forge
FM_FORGE_MAIL_REPO=own/mailbox")
out=$(checkrun "$H" check 2>&1); rc=$?
expect_rc "$rc" 0 "S10 the surfacing check exits 0"
printf '%s\n' "$out" | sed 's/^/  | /'
contains "$out" "forge-mail: new mail: woke for own/mailbox#7" "S10 new mail doorbells one line naming the message"
expect_rc "$(wake_rows "$H")" 1 "S10 the poll behind the check queued the durable wake"
out=$(checkrun "$H" check 2>&1); rc=$?
expect_rc "$rc" 0 "S10 the second check exits 0"
[ -z "$out" ] && ok "S10 the surfaced message is not re-reported (proven no-op silence)" || bad "S10 repeated report: $out"
H=$(mkhome s10-off)
out=$(checkrun "$H" check 2>&1); rc=$?
expect_rc "$rc" 0 "S10 an unconfigured home's check exits 0"
[ -z "$out" ] && ok "S10 an unconfigured home's check stays silent" || bad "S10 unconfigured check printed: $out"
[ ! -e "$H/state/.wake-queue" ] && ok "S10 nothing is queued for an unconfigured home" || bad "S10 unconfigured home queued a wake"
H=$(mkhome s10-slow "FM_FORGE_MAIL_HOST=mailbox.test.forge
FM_FORGE_MAIL_REPO=own/mailbox")
printf 8 > "$RIG/ctl/sleep"
out=$(env FM_FORGE_MAIL_CHECK_BUDGET=5 FM_HOME="$H" PATH="$RIG/fakebin:$PATH" HTTPS_PROXY="$PROXY" CURL_CA_BUNDLE="$RIG/ca.pem" "$CHECK" check 2>&1); rc=$?
expect_rc "$rc" 0 "S10 a timed-out check itself exits 0"
printf '%s\n' "$out" | sed 's/^/  | /'
contains "$out" "did not finish within the 5s budget" "S10 a poll that does not finish doorbells"
out=$(env FM_FORGE_MAIL_CHECK_BUDGET=5 FM_HOME="$H" PATH="$RIG/fakebin:$PATH" HTTPS_PROXY="$PROXY" CURL_CA_BUNDLE="$RIG/ca.pem" "$CHECK" check 2>&1); rc=$?
expect_rc "$rc" 0 "S10 the repeated timed-out check exits 0"
contains "$out" "did not finish within the 5s budget" "S10 a repeated timeout still doorbells (never silenced)"
rm -f "$RIG/ctl/sleep"; printf 0 > "$RIG/ctl/sleep"
H=$(mkhome s10-flap "FM_FORGE_MAIL_HOST=mailbox.test.forge
FM_FORGE_MAIL_REPO=own/mailbox")
printf x > "$RIG/ctl/refuse"
out=$(checkrun "$H" check 2>&1); rc=$?
expect_rc "$rc" 0 "S10 a pre-wake failure check exits 0"
printf '%s\n' "$out" | sed 's/^/  | /'
contains "$out" "could not reach" "S10 a first pre-wake failure reports one line"
out=$(checkrun "$H" check 2>&1); rc=$?
expect_rc "$rc" 0 "S10 the repeated pre-wake failure check exits 0"
[ -z "$out" ] && ok "S10 a repeated identical pre-wake failure silences" || bad "S10 repeated failure re-reported: $out"
rm -f "$RIG/ctl/refuse"

step "SUMMARY"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
