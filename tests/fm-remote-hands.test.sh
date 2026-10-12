#!/usr/bin/env bash
# Behavior tests for bin/fm-remote-hands.sh.
#
# The driver is a Docker Cloud Sandboxes client, so every case exercises the
# executable surface against a fake cloud: a fake sbx on PATH that records its
# argument vector and serves scripted exec outputs, a fake kubectl that hands
# out the two cluster-secret values, and a fake node that pins the local
# major. No case ever contacts the real cloud, the real cluster, or the real
# sbx CLI, and no real credential is ever loaded. The routing cases drive the
# real bin/fm-heavy-slot.sh against a scratch machine-state root, because the
# router's contract is its integration with the turnstile's public status
# surface, not a mock of it. Assertions read captured stdout, stderr, exit
# codes, argv logs, and manifest files, never driver source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HANDS="$ROOT/bin/fm-remote-hands.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-hands)
FAKEBIN="$TMP_ROOT/fakebin"
COREBIN="$TMP_ROOT/corebin"
SBX_LOG="$TMP_ROOT/sbx.argv.log"
KUBECTL_LOG="$TMP_ROOT/kubectl.argv.log"
EXEC_SEQ="$TMP_ROOT/exec-sequence.txt"
EXEC_CALLS="$TMP_ROOT/exec-calls.txt"
FAKE_DOCKER_ID=fake-docker-id
FAKE_DOCKER_PAT=fake-pat-never-print-me-0123456789

# make_fake_tools: fake sbx, fake kubectl, and a fake local node.
make_fake_tools() {
  mkdir -p "$FAKEBIN"
  cat > "$FAKEBIN/sbx" <<SH
#!/usr/bin/env bash
# Fake sandbox CLI. Records its full argument vector, consumes login stdin so
# the driver's pipe never blocks, and answers each --cloud exec call from the
# next line of the scripted output sequence. FM_FAKE_SBX_EXEC_RC fails every
# exec to simulate an unreachable sandbox; FM_FAKE_SBX_RC fails everything.
[ -z "\${FM_FAKE_SBX_LOG:-}" ] || printf '%s\n' "\$*" >> "\$FM_FAKE_SBX_LOG"
if [ "\$1" = login ]; then
  cat > /dev/null
  exit \${FM_FAKE_SBX_LOGIN_RC:-0}
fi
if [ "\${FM_FAKE_SBX_RC:-0}" != 0 ]; then
  exit "\${FM_FAKE_SBX_RC}"
fi
case "\$1 \$2" in
  '--cloud exec')
    if [ "\${FM_FAKE_SBX_EXEC_RC:-0}" != 0 ]; then exit "\${FM_FAKE_SBX_EXEC_RC}"; fi
    seq_file="\${FM_FAKE_SBX_EXEC_SEQ:?}"
    calls_file="\${FM_FAKE_SBX_EXEC_CALLS:?}"
    n=1
    if [ -f "\$calls_file" ]; then n=\$(( \$(cat "\$calls_file" 2>/dev/null || echo 0) + 1 )); fi
    printf '%s\n' "\$n" > "\$calls_file"
    sed -n "\${n}p" "\$seq_file"
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
  cat > "$FAKEBIN/kubectl" <<SH
#!/usr/bin/env bash
# Fake cluster-secret reader: answers the two keys the driver names from
# fixtures, records its argv, and never sees or prints a credential.
[ -z "\${FM_FAKE_KUBECTL_LOG:-}" ] || printf '%s\n' "\$*" >> "\$FM_FAKE_KUBECTL_LOG"
case "\$*" in
  *DOCKER_ID*)
    case "\${FM_FAKE_KUBECTL_MISSING:-}" in id) exit 1 ;; esac
    printf '%s' "$FAKE_DOCKER_ID" | base64
    ;;
  *DOCKER_PAT*)
    case "\${FM_FAKE_KUBECTL_MISSING:-}" in pat) exit 1 ;; esac
    printf '%s' "$FAKE_DOCKER_PAT" | base64
    ;;
esac
SH
  cat > "$FAKEBIN/node" <<SH
#!/usr/bin/env bash
# Fake local node: answers node -p process.versions.node with the local
# version (no leading v, exactly like the real -p output) to pin the major.
printf '%s\n' "\${FM_FAKE_LOCAL_NODE:-26.10.0}"
SH
  chmod +x "$FAKEBIN/sbx" "$FAKEBIN/kubectl" "$FAKEBIN/node"
  : > "$EXEC_SEQ"
  : > "$EXEC_CALLS"
}

# link_core_bin: a minimal real-tool PATH so single-tool-absence cases can
# scrub the ambient PATH without losing sed, tr, or the other basics.
link_core_bin() {
  mkdir -p "$COREBIN"
  local tool
  for tool in bash sed tr cut grep head awk cat mv mktemp rm mkdir date sleep timeout dirname basename base64; do
    [ -x "$COREBIN/$tool" ] || ln -s "$(command -v "$tool")" "$COREBIN/$tool"
  done
}

# hands <env...> -- <args...>: run the driver with the fake cloud on PATH and
# the scripted output sequence armed; captures stdout, stderr, and the code.
hands() {
  local envs=()
  while [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  HANDS_STDOUT=$(env "${envs[@]}" \
    FM_HOME="$HOME_UNDER_TEST" \
    PATH="$ACTIVE_PATH" \
    FM_FAKE_SBX_LOG="$SBX_LOG" \
    FM_FAKE_KUBECTL_LOG="$KUBECTL_LOG" \
    FM_FAKE_SBX_EXEC_SEQ="$EXEC_SEQ" \
    FM_FAKE_SBX_EXEC_CALLS="$EXEC_CALLS" \
    FM_TEST_SEAM=1 \
    "$HANDS" "$@" 2>"$TMP_ROOT/stderr"); HANDS_STATUS=$?
  HANDS_STDERR=$(cat "$TMP_ROOT/stderr")
}

# make_home <name> [env-file-lines...]: scratch home with an optional .env.
make_home() {
  local home
  home="$TMP_ROOT/$1"
  shift
  mkdir -p "$home"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$home/.env"
  fi
  HOME_UNDER_TEST="$home"
  printf '%s\n' "$home"
}

reset_logs() {
  : > "$SBX_LOG"
  : > "$KUBECTL_LOG"
  : > "$EXEC_CALLS"
  : > "$TMP_ROOT/stderr"
}

ACTIVE_PATH="$FAKEBIN:$PATH"
mkdir -p "$TMP_ROOT/default-home"
HOME_UNDER_TEST="$TMP_ROOT/default-home"

make_fake_tools
link_core_bin

test_help_and_usage_plumbing() {
  local out status
  hands FM_REMOTE_HANDS=1 -- --help; expect_code 0 "$HANDS_STATUS" "--help must exit 0"
  assert_contains "$HANDS_STDOUT" "fm-remote-hands.sh - Docker Cloud Sandboxes driver" \
    "--help did not render the header"
  hands FM_REMOTE_HANDS=1 -- frobnicate; expect_code 2 "$HANDS_STATUS" "unknown subcommand must exit 2"
  hands FM_REMOTE_HANDS=1 -- route --class bogus
  expect_code 2 "$HANDS_STATUS" "route with an invalid class must exit 2"
  hands FM_REMOTE_HANDS=1 -- create --name bad/name --class suite
  expect_code 2 "$HANDS_STATUS" "create with an unsafe name must exit 2"
  hands FM_REMOTE_HANDS=1 -- enabled extra
  expect_code 2 "$HANDS_STATUS" "enabled takes no arguments"
  pass "fm-remote-hands.sh: help, closed subcommand set, and argument validation"
}

test_off_by_default_is_a_hard_noop() {
  make_home off-home >/dev/null
  hands -- enabled
  expect_code 0 "$HANDS_STATUS" "enabled must exit 0 while off"
  assert_contains "$HANDS_STDOUT" "off" "enabled must print off on an unconfigured home"
  hands -- route --class sweep
  expect_code 0 "$HANDS_STATUS" "route must exit 0 while off"
  assert_contains "$HANDS_STDOUT" "local reason=off" "route on an off home must print the off decision"
  hands -- create --class sweep --name t-off
  expect_code 1 "$HANDS_STATUS" "create must refuse while off"
  assert_contains "$HANDS_STDERR" "FM_REMOTE_HANDS" "the refusal must name the enabling value"
  [ ! -e "$SBX_LOG" ] || [ ! -s "$SBX_LOG" ] || fail "create while off must not touch the sandbox CLI"
  hands FM_REMOTE_HANDS=0 -- enabled
  assert_contains "$HANDS_STDOUT" "off" "FM_REMOTE_HANDS=0 must stay off"
  hands FM_REMOTE_HANDS=off -- route --class sweep
  assert_contains "$HANDS_STDOUT" "reason=off" "FM_REMOTE_HANDS=off must stay off"
  pass "fm-remote-hands.sh: off by default with a silent route and loud create refusal"
}

test_env_file_activation_and_env_wins() {
  make_home env-home "FM_REMOTE_HANDS=1" >/dev/null
  hands -- enabled
  assert_contains "$HANDS_STDOUT" "on" "a home .env must switch the lane on"
  hands FM_REMOTE_HANDS=0 -- enabled
  assert_contains "$HANDS_STDOUT" "off" "an explicit environment value must win over .env"
  hands FM_REMOTE_HANDS=true -- enabled
  assert_contains "$HANDS_STDOUT" "on" "truthy environment values switch the lane on"
  pass "fm-remote-hands.sh: .env activation with the env-wins contract"
}

test_route_local_memory_decisions() {
  make_home route-home >/dev/null
  local xdg="$TMP_ROOT/route-xdg"
  mkdir -p "$xdg"
  hands FM_REMOTE_HANDS=1 FM_REMOTE_HANDS_LOCAL_MEM_MB=7900 XDG_STATE_HOME="$xdg" -- route --class sweep
  expect_code 0 "$HANDS_STATUS" "route sweep must decide, not fail"
  assert_contains "$HANDS_STDOUT" "sandbox shape=large class=sweep reason=oversized peak=6144MB local=7900MB" \
    "the sweep class must route to a Large sandbox on an 8 GiB machine"
  hands FM_REMOTE_HANDS=1 FM_REMOTE_HANDS_LOCAL_MEM_MB=7900 XDG_STATE_HOME="$xdg" -- route --class suite
  assert_contains "$HANDS_STDOUT" "local reason=fits class=suite peak=4096MB local=7900MB" \
    "the suite class must fit an 8 GiB machine"
  hands FM_REMOTE_HANDS=1 FM_REMOTE_HANDS_LOCAL_MEM_MB=16000 XDG_STATE_HOME="$xdg" -- route --class sweep
  assert_contains "$HANDS_STDOUT" "local reason=fits class=sweep peak=6144MB local=16000MB" \
    "a 16 GiB machine must keep the sweep local"
  hands FM_REMOTE_HANDS=1 FM_REMOTE_HANDS_LOCAL_MEM_MB=7900 XDG_STATE_HOME="$xdg" -- route --class other --estimate 6000
  assert_contains "$HANDS_STDOUT" "reason=oversized peak=6000MB" \
    "an explicit --estimate must override the class peak"
  hands FM_REMOTE_HANDS=1 XDG_STATE_HOME="$xdg" -- route --class suite
  printf '%s\n' "$HANDS_STDOUT" | grep -qE 'local=[0-9]+MB' \
    || fail "without the seam the router must detect real machine RAM (got: $HANDS_STDOUT)"
  pass "fm-remote-hands.sh: routing follows the class peak against local RAM"
}

test_route_reads_the_real_heavy_slot() {
  local xdg slot_home
  slot_home=$(make_home slot-home)
  xdg="$slot_home/xdg"
  mkdir -p "$xdg"
  XDG_STATE_HOME="$xdg" "$ROOT/bin/fm-heavy-slot.sh" acquire other-task --estimate 4000 >/dev/null 2>&1
  hands FM_REMOTE_HANDS=1 FM_REMOTE_HANDS_LOCAL_MEM_MB=16000 XDG_STATE_HOME="$xdg" -- route --class suite
  assert_contains "$HANDS_STDOUT" "sandbox shape=medium class=suite reason=slot-held holder=other-task" \
    "a live heavy-slot holder must reroute the class to the sandbox"
  hands FM_REMOTE_HANDS=1 FM_REMOTE_HANDS_LOCAL_MEM_MB=16000 XDG_STATE_HOME="$xdg" -- route --class suite --task other-task
  assert_contains "$HANDS_STDOUT" "local reason=fits" \
    "the holder itself asking for its own task must stay local"
  XDG_STATE_HOME="$xdg" "$ROOT/bin/fm-heavy-slot.sh" release other-task >/dev/null 2>&1
  hands FM_REMOTE_HANDS=1 FM_REMOTE_HANDS_LOCAL_MEM_MB=16000 XDG_STATE_HOME="$xdg" -- route --class suite
  assert_contains "$HANDS_STDOUT" "local reason=fits" "a released slot must route local again"
  XDG_STATE_HOME="$xdg" "$ROOT/bin/fm-heavy-slot.sh" acquire stale-task --estimate 4000 --expiry 1 >/dev/null 2>&1
  sleep 2
  hands FM_REMOTE_HANDS=1 FM_REMOTE_HANDS_LOCAL_MEM_MB=16000 XDG_STATE_HOME="$xdg" -- route --class suite
  assert_contains "$HANDS_STDOUT" "local reason=fits" \
    "a stale heavy-slot holder must not reroute; acquire would take it over"
  XDG_STATE_HOME="$xdg" "$ROOT/bin/fm-heavy-slot.sh" release stale-task >/dev/null 2>&1
  pass "fm-remote-hands.sh: routing integrates the heavy slot's public status"
}

test_create_sizes_shapes_ttl_and_allowances() {
  make_home create-home >/dev/null
  reset_logs
  hands FM_REMOTE_HANDS=1 -- create --class sweep --name t-sweep --expected-mins 100
  expect_code 0 "$HANDS_STATUS" "create sweep must succeed against the fake cloud"
  local create_line
  create_line=$(grep -F -- '--cloud create' "$SBX_LOG")
  assert_contains "$create_line" "--name t-sweep --cpus 8 --memory 16g --ttl 150m --on-timeout delete" \
    "the sweep class must create a Large sandbox with wall-plus-50% TTL and delete-on-timeout"
  assert_contains "$create_line" "--allow-network github.com:443" "github.com must be allowed"
  assert_contains "$create_line" "--allow-network release-assets.githubusercontent.com:443" \
    "the GitHub release CDN must be allowed"
  assert_contains "$create_line" "--allow-network raw.githubusercontent.com:443" \
    "the GitHub raw CDN must be allowed"
  assert_contains "$create_line" "--allow-network nodejs.org:443 --allow-network registry.npmjs.org:443" \
    "the pinned-node and npm hosts must be allowed"
  assert_contains "$create_line" " shell" "creation must use the bare shell agent"
  assert_grep "login --username $FAKE_DOCKER_ID --password-stdin" "$SBX_LOG" \
    "login must precede creation with the PAT on stdin only"
  local manifest="$HOME_UNDER_TEST/state/remote-hands/t-sweep.rec"
  [ -f "$manifest" ] || fail "create must record the sandbox manifest"
  assert_grep "class=sweep" "$manifest" "the manifest must record the class"
  assert_grep "shape=large" "$manifest" "the manifest must record the shape"
  assert_grep "ttl=150m" "$manifest" "the manifest must record the TTL"
  assert_grep "created=" "$manifest" "the manifest must stamp creation"
  reset_logs
  hands FM_REMOTE_HANDS=1 -- create --class suite --name t-suite --expected-mins 80
  create_line=$(grep -F -- '--cloud create' "$SBX_LOG")
  assert_contains "$create_line" "--cpus 4 --memory 8g --ttl 2h" \
    "the suite class must create a Medium sandbox and whole-hour TTLs render as Nh"
  reset_logs
  hands FM_REMOTE_HANDS=1 FM_REMOTE_HANDS_TTL_MARGIN=100 -- create --class suite --name t-margin --expected-mins 100
  create_line=$(grep -F -- '--cloud create' "$SBX_LOG")
  assert_contains "$create_line" "--ttl 200m" "FM_REMOTE_HANDS_TTL_MARGIN must size the TTL margin"
  reset_logs
  hands FM_REMOTE_HANDS=1 -- create --class suite --name t-cap --expected-mins 1200
  create_line=$(grep -F -- '--cloud create' "$SBX_LOG")
  assert_contains "$create_line" "--ttl 24h" "TTL must clamp to the platform's 24 h ceiling"
  assert_contains "$HANDS_STDERR" "24 h ceiling" "the clamp must be loud"
  reset_logs
  hands FM_REMOTE_HANDS=1 -- create --class suite --name t-extra --allow example.test:8443 --expected-mins 60
  create_line=$(grep -F -- '--cloud create' "$SBX_LOG")
  assert_contains "$create_line" "--allow-network example.test:8443" "--allow extras must extend the allowances"
  hands FM_REMOTE_HANDS=1 -- create --class suite --name t-badport --allow example.test
  expect_code 2 "$HANDS_STATUS" "an allowance without a port must be refused"
  hands FM_REMOTE_HANDS=1 -- create --class suite --name t-badmins --expected-mins 0
  expect_code 2 "$HANDS_STATUS" "a zero expected wall must be refused"
  pass "fm-remote-hands.sh: create sizes shape, TTL, allowances, and manifest per class"
}

test_exec_hosts_the_job_on_a_dedicated_tmux_socket() {
  make_home exec-home >/dev/null
  reset_logs
  hands FM_REMOTE_HANDS=1 -- exec --name t-exec -- make test 'X=1 y'
  expect_code 0 "$HANDS_STATUS" "exec must succeed against the fake cloud"
  local exec_text
  exec_text=$(cat "$SBX_LOG")
  assert_contains "$exec_text" "--cloud exec t-exec -- bash -lc" "exec must go through the cloud exec stream"
  assert_contains "$exec_text" "tmux -L fm-hands new-session -d -s fm-hands" \
    "the job must launch under a daemonized tmux on the dedicated socket"
  assert_contains "$exec_text" "LANG=C.UTF-8 LC_ALL=C.UTF-8" "the fidelity locale must be pinned"
  assert_contains "$exec_text" "/tmp/fm-hands.exit" "the exit marker path must be the hosted one"
  assert_contains "$exec_text" "X=1 y" "command words with spaces must survive the quoting layers"
  hands FM_REMOTE_HANDS=1 -- exec --name t-exec
  expect_code 2 "$HANDS_STATUS" "exec without a command must be refused"
  pass "fm-remote-hands.sh: exec survives exec-stream teardown via the hosted socket"
}

test_wait_propagates_the_hosted_exit_code() {
  make_home wait-home >/dev/null
  reset_logs
  printf '\n7\n' > "$EXEC_SEQ"
  hands FM_REMOTE_HANDS=1 -- wait --name t-wait --interval 1 --max-secs 30
  expect_code 7 "$HANDS_STATUS" "wait must exit with the hosted job's own code"
  assert_contains "$HANDS_STDOUT" "exit=7" "wait must print the exit marker"
  reset_logs
  printf '\n' > "$EXEC_SEQ"
  FM_FAKE_SBX_EXEC_RC=1 hands FM_REMOTE_HANDS=1 -- wait --name t-gone --interval 1 --max-secs 30
  expect_code 1 "$HANDS_STATUS" "an unreachable sandbox must abort the wait"
  assert_contains "$HANDS_STDERR" "t-gone" "the abort must name the sandbox"
  reset_logs
  printf ' \n' > "$EXEC_SEQ"
  hands FM_REMOTE_HANDS=1 -- wait --name t-slow --interval 1 --max-secs 1
  expect_code 1 "$HANDS_STATUS" "a bounded wait with no marker must time out"
  assert_contains "$HANDS_STDERR" "timed out after 1s" "the timeout must name its bound"
  pass "fm-remote-hands.sh: wait polls the marker and propagates or aborts"
}

test_copy_and_log_paths() {
  make_home copy-home >/dev/null
  reset_logs
  hands FM_REMOTE_HANDS=1 -- copy-in --name t-copy "$TMP_ROOT/local-build.tar"
  expect_code 0 "$HANDS_STATUS" "copy-in must succeed"
  assert_grep "--cloud cp $TMP_ROOT/local-build.tar t-copy:/home/agent/workspace/" "$SBX_LOG" \
    "copy-in must default to the workspace destination"
  reset_logs
  hands FM_REMOTE_HANDS=1 -- copy-in --name t-copy "$TMP_ROOT/local-build.tar" /tmp/stage/
  assert_grep "--cloud cp $TMP_ROOT/local-build.tar t-copy:/tmp/stage/" "$SBX_LOG" \
    "copy-in must honor an explicit destination"
  reset_logs
  hands FM_REMOTE_HANDS=1 -- copy-out --name t-copy /home/agent/workspace/out.json "$TMP_ROOT/out.json"
  expect_code 0 "$HANDS_STATUS" "copy-out must succeed"
  assert_grep "--cloud cp t-copy:/home/agent/workspace/out.json $TMP_ROOT/out.json" "$SBX_LOG" \
    "copy-out must pull the artifact out of the sandbox"
  reset_logs
  ( cd "$TMP_ROOT" && env FM_HOME="$HOME_UNDER_TEST" PATH="$ACTIVE_PATH" \
    FM_FAKE_SBX_LOG="$SBX_LOG" FM_FAKE_KUBECTL_LOG="$KUBECTL_LOG" \
    FM_FAKE_SBX_EXEC_SEQ="$EXEC_SEQ" FM_FAKE_SBX_EXEC_CALLS="$EXEC_CALLS" \
    FM_TEST_SEAM=1 FM_REMOTE_HANDS=1 "$HANDS" log --name t-copy >/dev/null )
  expect_code 0 "$?" "log must succeed"
  assert_grep "--cloud cp t-copy:/tmp/fm-hands.log ./fm-hands-t-copy.log" "$SBX_LOG" \
    "log must pull the hosted job log to its default path"
  hands FM_REMOTE_HANDS=1 -- copy-out --name t-copy only-one-arg
  expect_code 2 "$HANDS_STATUS" "copy-out must demand both paths"
  pass "fm-remote-hands.sh: copy-in, copy-out, and log drive the artifact paths"
}

test_teardown_removes_and_cleans_the_manifest() {
  make_home teardown-home >/dev/null
  reset_logs
  hands FM_REMOTE_HANDS=1 -- create --class suite --name t-down --expected-mins 60
  expect_code 0 "$HANDS_STATUS" "setup create for teardown must succeed"
  [ -f "$HOME_UNDER_TEST/state/remote-hands/t-down.rec" ] || fail "manifest must exist before teardown"
  reset_logs
  hands FM_REMOTE_HANDS=1 -- teardown --name t-down
  expect_code 0 "$HANDS_STATUS" "teardown must succeed"
  assert_grep "--cloud rm --force t-down" "$SBX_LOG" "teardown must force-remove the sandbox"
  assert_absent "$HOME_UNDER_TEST/state/remote-hands/t-down.rec" \
    "teardown must delete the manifest"
  reset_logs
  hands -- teardown --name t-down
  expect_code 0 "$HANDS_STATUS" "teardown must work while the lane is off"
  assert_contains "$HANDS_STDERR" "no manifest existed" "a manifest-less teardown must note it"
  assert_grep "--cloud rm --force t-down" "$SBX_LOG" "the off-lane teardown must still remove"
  pass "fm-remote-hands.sh: teardown removes the sandbox and its record, even while off"
}

test_credentials_load_in_process_and_never_leak() {
  make_home cred-home >/dev/null
  reset_logs
  hands FM_REMOTE_HANDS=1 -- create --class suite --name t-cred --expected-mins 60
  expect_code 0 "$HANDS_STATUS" "create with the fake secret must succeed"
  local leak_target
  for leak_target in "$SBX_LOG" "$KUBECTL_LOG" "$TMP_ROOT/stderr"; do
    assert_no_grep "$FAKE_DOCKER_PAT" "$leak_target" "the PAT leaked into $leak_target"
  done
  assert_not_contains "$HANDS_STDOUT" "$FAKE_DOCKER_PAT" "the PAT leaked into driver stdout"
  assert_grep "get secret opencode-docker-cloud" "$KUBECTL_LOG" \
    "the default secret ref must be read from its namespace"
  reset_logs
  hands FM_REMOTE_HANDS=1 FM_REMOTE_HANDS_SECRET=team/docker-sbx -- create --class suite --name t-sec --expected-mins 60
  expect_code 0 "$HANDS_STATUS" "create with a custom secret ref must succeed"
  assert_grep "-n team get secret docker-sbx" "$KUBECTL_LOG" \
    "a custom FM_REMOTE_HANDS_SECRET must split into namespace and secret"
  hands FM_REMOTE_HANDS=1 FM_REMOTE_HANDS_SECRET=no-slash -- create --class suite --name t-sec
  expect_code 2 "$HANDS_STATUS" "a secret ref without a namespace must be refused"
  assert_contains "$HANDS_STDERR" "no-slash" "the refusal must name the bad ref"
  reset_logs
  FM_FAKE_KUBECTL_MISSING=pat hands FM_REMOTE_HANDS=1 -- create --class suite --name t-nopat
  expect_code 1 "$HANDS_STATUS" "a secret missing the PAT must fail create"
  assert_contains "$HANDS_STDERR" "opencode/opencode-docker-cloud" "the failure must name the secret ref"
  assert_no_grep "$FAKE_DOCKER_PAT" "$TMP_ROOT/stderr" "the missing-PAT path must not echo any value"
  pass "fm-remote-hands.sh: credentials cross stdin only and never surface"
}

test_missing_tools_fail_closed() {
  make_home tools-home >/dev/null
  mkdir -p "$TMP_ROOT/kubectl-only" "$TMP_ROOT/sbx-only"
  ln -sf "$FAKEBIN/kubectl" "$TMP_ROOT/kubectl-only/kubectl"
  ln -sf "$FAKEBIN/sbx" "$TMP_ROOT/sbx-only/sbx"
  local out status
  out=$(env FM_HOME="$HOME_UNDER_TEST" FM_REMOTE_HANDS=1 PATH="$COREBIN:$TMP_ROOT/kubectl-only" \
    FM_FAKE_SBX_LOG=/dev/null FM_TEST_SEAM=1 \
    "$HANDS" create --class suite --name t-nosbx 2>&1); status=$?
  expect_code 1 "$status" "create without the sbx CLI must fail closed"
  assert_contains "$out" "sbx CLI" "the failure must name the sbx CLI"
  out=$(env FM_HOME="$HOME_UNDER_TEST" FM_REMOTE_HANDS=1 PATH="$COREBIN:$TMP_ROOT/sbx-only" \
    FM_FAKE_SBX_LOG=/dev/null FM_TEST_SEAM=1 \
    "$HANDS" create --class suite --name t-nokubectl 2>&1); status=$?
  expect_code 1 "$status" "create without kubectl must fail closed"
  assert_contains "$out" "kubectl" "the failure must name kubectl"
  pass "fm-remote-hands.sh: missing tooling fails closed with named prerequisites"
}

test_prepare_pins_the_fidelity_recipe() {
  make_home prep-home >/dev/null
  reset_logs
  printf '22.22.1\n' > "$EXEC_SEQ"
  hands FM_REMOTE_HANDS=1 -- prepare --name t-prep --repo https://github.com/kirkins/firstmate
  expect_code 0 "$HANDS_STATUS" "prepare must succeed against the fake cloud"
  local apt_text
  apt_text=$(cat "$SBX_LOG")
  assert_contains "$apt_text" "xz-utils tmux libatomic1 ruby gcc time" \
    "prepare must install the closed fidelity tool set"
  assert_contains "$apt_text" "latest-v26.x" \
    "prepare must pin node to the local machine's major"
  assert_contains "$apt_text" "SHASUMS256.txt" "the node tarball must be SHA-verified"
  assert_contains "$apt_text" "sha256sum -c" "the node tarball check must be enforced"
  assert_contains "$apt_text" "git clone" "prepare must clone the requested repository"
  assert_contains "$apt_text" "https://github.com/kirkins/firstmate" \
    "the clone command must carry the repository URL"
  # shellcheck disable=SC2016  # $dest is the sandbox-side variable the driver quotes into the clone script.
  assert_contains "$apt_text" '"$dest"' "the clone must target the derived destination variable"
  assert_contains "$apt_text" "/home/agent/workspace/firstmate" \
    "the default destination must derive from the repository name"
  assert_contains "$apt_text" "fetch --unshallow" \
    "prepare must heal an existing shallow clone"
  assert_not_contains "$apt_text" " --depth" "prepare must never pass --depth"
  assert_no_grep "--depth" "$SBX_LOG" "no driver command may clone shallow"
  assert_no_grep " secret set" "$SBX_LOG" "the driver must never set a provider credential in a sandbox"
  assert_no_grep "zellij" "$SBX_LOG" "zellij must never be installed"
  reset_logs
  printf '26.10.0\n' > "$EXEC_SEQ"
  hands FM_REMOTE_HANDS=1 -- prepare --name t-prep --repo https://github.com/kirkins/firstmate
  expect_code 0 "$HANDS_STATUS" "a matching node major must still prepare cleanly"
  apt_text=$(cat "$SBX_LOG")
  assert_not_contains "$apt_text" "nodejs.org" \
    "a matching node major must skip the node install entirely"
  reset_logs
  printf '22.22.1\n' > "$EXEC_SEQ"
  hands FM_REMOTE_HANDS=1 -- prepare --name t-prep --repo https://github.com/kirkins/firstmate --node-major 20
  apt_text=$(cat "$SBX_LOG")
  assert_contains "$apt_text" "latest-v20.x" "--node-major must override the local major"
  reset_logs
  printf '22.22.1\n' > "$EXEC_SEQ"
  hands FM_REMOTE_HANDS=1 -- prepare --name t-prep --repo https://github.com/kirkins/firstmate --branch fm-lane --dest /srv/repo
  apt_text=$(cat "$SBX_LOG")
  assert_contains "$apt_text" "--branch" "--branch must reach the clone"
  assert_contains "$apt_text" "fm-lane" "the branch value must be carried through quoting"
  assert_contains "$apt_text" "/srv/repo" "--dest must override the destination"
  hands FM_REMOTE_HANDS=1 -- prepare --name t-prep --repo not-a-url
  expect_code 2 "$HANDS_STATUS" "a non-URL --repo must be refused"
  pass "fm-remote-hands.sh: prepare pins locale, node major, SHA checks, and full clones"
}

test_prepare_without_local_node_pins_nothing_loudly() {
  make_home nonode-home >/dev/null
  mkdir -p "$TMP_ROOT/nonode-bin"
  ln -sf "$FAKEBIN/sbx" "$TMP_ROOT/nonode-bin/sbx"
  ln -sf "$FAKEBIN/kubectl" "$TMP_ROOT/nonode-bin/kubectl"
  reset_logs
  printf '22.22.1\n' > "$EXEC_SEQ"
  ACTIVE_PATH_SAVED=$ACTIVE_PATH
  ACTIVE_PATH="$TMP_ROOT/nonode-bin:$COREBIN"
  hands FM_REMOTE_HANDS=1 -- prepare --name t-nonode --repo https://github.com/kirkins/firstmate
  expect_code 0 "$HANDS_STATUS" "prepare without local node must still succeed"
  ACTIVE_PATH=$ACTIVE_PATH_SAVED
  local apt_text
  apt_text=$(cat "$SBX_LOG")
  assert_not_contains "$apt_text" "nodejs.org" "no local node must mean no node install"
  assert_contains "$HANDS_STDERR" "no local node" "the skip must be loud"
  pass "fm-remote-hands.sh: prepare skips the node pin loudly when it cannot name one"
}

test_help_and_usage_plumbing
test_off_by_default_is_a_hard_noop
test_env_file_activation_and_env_wins
test_route_local_memory_decisions
test_route_reads_the_real_heavy_slot
test_create_sizes_shapes_ttl_and_allowances
test_exec_hosts_the_job_on_a_dedicated_tmux_socket
test_wait_propagates_the_hosted_exit_code
test_copy_and_log_paths
test_teardown_removes_and_cleans_the_manifest
test_credentials_load_in_process_and_never_leak
test_missing_tools_fail_closed
test_prepare_pins_the_fidelity_recipe
test_prepare_without_local_node_pins_nothing_loudly
