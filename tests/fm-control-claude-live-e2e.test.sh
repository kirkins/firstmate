#!/usr/bin/env bash
# Token-free live Claude exit guard: ordinary /exit and the native-key fallback.
# A scoped shim deliberately hides the typed /exit from its payload-proof read,
# reproducing a failed proof without guessing a vendor rendering regression.
# Claude, its composer, keys, processes, and endpoint remain real.
# Every Herdr call is routed through the guarded named-session lab helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_CONTROL_CLAUDE_LIVE_E2E herdr jq claude

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_HOME_HELPER=${FM_LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name control-claude-exit)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-claude-live.XXXXXX")
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
LAB_HOME="$TMP_ROOT/home"
export FM_HOME="$LAB_HOME"
FAKEBIN="$TMP_ROOT/fakebin"
LAB_CREATED=0
LAB_PROVISIONED=0
cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$LAB_CREATED" = 1 ]; then
    PATH="$ORIGINAL_PATH" "$LAB_HOME_HELPER" teardown "$LAB_HOME" || rc=1
  fi
  if [ "$LAB_PROVISIONED" = 1 ]; then
    PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" || rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT
"$LAB_HOME_HELPER" create "$LAB_HOME" >/dev/null || fail "could not mark the isolated lab home"
LAB_CREATED=1
LAB_PROVISIONED=1
"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
mkdir -p "$FAKEBIN"

export FM_EXIT_LAB_HELPER="$LAB_HELPER" FM_EXIT_LAB_SESSION="$SESSION"
export FM_EXIT_LAB_PATH="$ORIGINAL_PATH" FM_EXIT_LAB_PROOF="$TMP_ROOT"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ]; then
  [ "${args[$((n-1))]}" = "$FM_EXIT_LAB_SESSION" ] || exit 97
  args=("${args[@]:0:$((n-2))}")
else
  echo "wrapper requires the exact lab --session" >&2
  exit 98
fi
lab_call() {
  env PATH="$FM_EXIT_LAB_PATH" "$FM_EXIT_LAB_HELPER" run "$FM_EXIT_LAB_SESSION" "${args[@]}"
}
if [ -f "$FM_EXIT_LAB_PROOF/inject" ]; then
  if [ "${args[0]}:${args[1]:-}:${args[3]:-}" = pane:send-text:/exit ]; then
    lab_call || exit $?
    : > "$FM_EXIT_LAB_PROOF/proof-pending"
    exit 0
  fi
  if [ -f "$FM_EXIT_LAB_PROOF/proof-pending" ] && [ "${args[0]}:${args[1]:-}" = pane:read ]; then
    : > "$FM_EXIT_LAB_PROOF/proof-hidden"
    cat "$FM_EXIT_LAB_PROOF/empty.ansi"
    exit 0
  fi
  if [ "${args[0]}:${args[1]:-}:${args[3]:-}" = pane:send-keys:ctrl+u ]; then
    lab_call || exit $?
    rm -f "$FM_EXIT_LAB_PROOF/proof-pending"
    exit 0
  fi
  if [ "${args[0]}:${args[1]:-}" = pane:send-keys ]; then
    printf '%s\n' "${args[3]:-}" >> "$FM_EXIT_LAB_PROOF/fallback-keys"
  fi
fi
exec env PATH="$FM_EXIT_LAB_PATH" "$FM_EXIT_LAB_HELPER" run "$FM_EXIT_LAB_SESSION" "${args[@]}"
SH
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$ORIGINAL_PATH"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "could not load the Herdr adapter"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>&1 | head -1)
HERDR_VERSION=$(lab status --json | jq -r '.client.version // "unknown"')
version_fail() { fail "$1 [Claude $VERSION; Herdr $HERDR_VERSION]"; }
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-native-exit --no-focus) \
  || version_fail "could not create the isolated workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || version_fail "workspace create returned no pane"
WORKSPACE=$(printf '%s' "$WS_JSON" | jq -er '.result.workspace.workspace_id') \
  || version_fail "workspace create returned no workspace"
TAB=$(printf '%s' "$WS_JSON" | jq -er '.result.tab.tab_id') \
  || version_fail "workspace create returned no tab"
TARGET="$SESSION:$PANE"
cat > "$LAB_HOME/state/native-exit.meta" <<EOF
window=$TARGET
endpoint_task_id=native-exit
worktree=$ROOT
project=$ROOT
harness=claude
kind=ship
mode=no-mistakes
yolo=off
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WORKSPACE
herdr_tab_id=$TAB
herdr_pane_id=$PANE
EOF

launch_claude() {
  [ "$(fm_backend_agent_state herdr "$TARGET")" = dead ] \
    || version_fail "refusing to launch into a pane that is not agent-free"
  # Safe mode isolates vendor key behavior from user/project startup hooks.
  lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --safe-mode --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
    || version_fail "could not launch Claude"
  local i=0 screen
  while [ "$i" -lt 60 ]; do
    screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
    if [[ "$screen" == *'bypass permissions on'* ]] \
      && [ "$(fm_backend_herdr_composer_state "$TARGET")" = empty ] \
      && [ "$(fm_backend_agent_state herdr "$TARGET")" = alive ]; then
      return 0
    fi
    i=$((i + 1))
    sleep 0.5
  done
  version_fail "Claude never reached an empty live composer; inspect trust or login"
}

run_control() {
  env FM_HOME="$LAB_HOME" FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= \
    FM_CONFIG_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=5 \
    bash "$ROOT/bin/fm-control.sh" native-exit exit 2>&1
}

launch_claude
lab pane send-text "$PANE" 'preserve this draft' >/dev/null || version_fail "could not type the lab draft"
OUT=$(run_control); RC=$?
[ "$RC" = 1 ] && [[ "$OUT" == *'composer visibly holds pending text'* ]] \
  || version_fail "exit did not refuse a real draft: $OUT"
CONTENT=$(fm_backend_herdr_composer_content "$TARGET")
[ "$CONTENT" = 'preserve this draft' ] || version_fail "exit changed the refused draft: $CONTENT"
lab pane send-keys "$PANE" ctrl+u >/dev/null || version_fail "could not clear the lab-owned draft"
OUT=$(run_control); RC=$?
[ "$RC" = 0 ] && [[ "$OUT" == 'stopped native-exit '* ]] \
  || version_fail "ordinary text exit failed: $OUT"
[ "$(fm_backend_agent_state herdr "$TARGET")" = dead ] || version_fail "ordinary exit did not stop Claude"
pass "live Claude exit ($VERSION; Herdr $HERDR_VERSION): preserves a draft and exits normally"

launch_claude
lab pane read "$PANE" --source visible --format ansi > "$TMP_ROOT/empty.ansi" \
  || version_fail "could not capture the empty proof baseline"
: > "$TMP_ROOT/inject"
OUT=$(run_control); RC=$?
[ -f "$TMP_ROOT/proof-hidden" ] || version_fail "the failed payload proof was not exercised"
[ "$RC" = 0 ] && [[ "$OUT" == 'stopped native-exit '* ]] \
  || version_fail "native exit fallback failed after the hidden payload proof: $OUT"
[ "$(cat "$TMP_ROOT/fallback-keys")" = $'ctrl+d\nctrl+d' ] \
  || version_fail "the fallback did not arm and confirm exit with exactly two native keys"
[ "$(fm_backend_agent_state herdr "$TARGET")" = dead ] || version_fail "fallback reported success with Claude still alive"
lab pane get "$PANE" >/dev/null || version_fail "fallback destroyed the endpoint"
[ "$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE")" = shell ] \
  || version_fail "fallback did not preserve the pane's shell"
pass "live Claude exit ($VERSION; Herdr $HERDR_VERSION): failed payload proof exits with native keys and preserves the shell"
