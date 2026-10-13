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
SBX_ARGV_LOG="$TMP_ROOT/sbx.args.log"
TIMEOUT_LOG="$TMP_ROOT/timeout.argv.log"
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
# Fake sandbox CLI. Records its full argument vector (joined, plus one
# record-separator-delimited argument per invocation when FM_FAKE_SBX_ARGV_LOG
# is armed), consumes login stdin so the driver's pipe never blocks, and
# answers each --cloud exec call from the next line of the scripted output
# sequence. FM_FAKE_SBX_EXECUTE executes the preserved post-separator argv,
# as sbx 0.47.0 does, instead of serving scripted output. Only the sandbox's
# marker paths are remapped into scratch space. Local shell profiles are
# suppressed so they cannot replace the fixture PATH. FM_FAKE_SBX_EXEC_RC fails every exec to
# simulate an unreachable sandbox; FM_FAKE_SBX_RC fails everything.
[ -z "\${FM_FAKE_SBX_LOG:-}" ] || printf '%s\n' "\$*" >> "\$FM_FAKE_SBX_LOG"
if [ -n "\${FM_FAKE_SBX_ARGV_LOG:-}" ]; then
  for a in "\$@"; do printf '%s' "\$a"; printf '\036'; done > "\${FM_FAKE_SBX_ARGV_LOG}"
fi
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
    if [ "\${FM_FAKE_SBX_EXECUTE:-0}" = 1 ]; then
      shift 4
      args=()
      for arg in "\$@"; do
        arg=\${arg//\/tmp\/fm-hands/\$FM_FAKE_SBX_REMOTE_TMP\/fm-hands}
        arg=\${arg//\/tmp\/\\\$file/\$FM_FAKE_SBX_REMOTE_TMP\/\\\$file}
        arg=\${arg//'(cd /tmp &&'/'(cd "'\$FM_FAKE_SBX_REMOTE_TMP'" &&'}
        args+=("\$arg")
      done
      set -- "\${args[@]}"
      if [ "\${2:-}" = -lc ]; then
        set -- "\$1" "\$2" "export PATH=\$(printf '%q' "\$PATH"); \$3" "\${@:4}"
      fi
      if [ "\$1" = bash ]; then
        shift
        exec bash --noprofile --norc "\$@"
      fi
      exec "\$@"
    fi
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
  cat > "$FAKEBIN/timeout" <<SH
#!/usr/bin/env bash
# Fake timeout wrapper: records "<secs> <command>" when FM_FAKE_TIMEOUT_LOG is
# armed, then runs the command unbounded; the tests assert the bound the
# driver chose for each call, not that the bound kills anything.
[ -z "\${FM_FAKE_TIMEOUT_LOG:-}" ] || printf '%s\n' "\$*" >> "\${FM_FAKE_TIMEOUT_LOG}"
shift
exec "\$@"
SH
  chmod +x "$FAKEBIN/timeout"
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
  HANDS_STDOUT=$(env ${envs[@]+"${envs[@]}"} \
    FM_HOME="$HOME_UNDER_TEST" \
    PATH="$ACTIVE_PATH" \
    FM_FAKE_SBX_LOG="$SBX_LOG" \
    FM_FAKE_KUBECTL_LOG="$KUBECTL_LOG" \
    FM_FAKE_SBX_EXEC_SEQ="$EXEC_SEQ" \
    FM_FAKE_SBX_EXEC_CALLS="$EXEC_CALLS" \
    FM_FAKE_SBX_REMOTE_TMP="$TMP_ROOT/remote" \
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
  : > "$SBX_ARGV_LOG"
  : > "$TIMEOUT_LOG"
  : > "$KUBECTL_LOG"
  : > "$EXEC_CALLS"
  : > "$TMP_ROOT/stderr"
}

ACTIVE_PATH="$FAKEBIN:$PATH"
mkdir -p "$TMP_ROOT/default-home"
HOME_UNDER_TEST="$TMP_ROOT/default-home"

make_fake_tools
link_core_bin
mkdir -p "$TMP_ROOT/remote"

test_help_and_usage_plumbing() {
  local out status
  hands FM_REMOTE_HANDS=1 -- --help; expect_code 0 "$HANDS_STATUS" "--help must exit 0"
  assert_contains "$HANDS_STDOUT" "fm-remote-hands.sh - Docker Cloud Sandboxes driver" \
    "--help did not render the header"
  hands FM_REMOTE_HANDS=1 -- frobnicate; expect_code 2 "$HANDS_STATUS" "unknown subcommand must exit 2"
  hands FM_REMOTE_HANDS=1 -- route --class bogus
  expect_code 2 "$HANDS_STATUS" "route with an invalid class must exit 2"
  hands FM_REMOTE_HANDS=1 -- route --class suite --estimate 6000
  expect_code 2 "$HANDS_STATUS" "route must reject unknown or removed arguments"
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
  hands FM_REMOTE_HANDS=1 FM_REMOTE_HANDS_LOCAL_MEM_MB=7900 XDG_STATE_HOME="$xdg" -- route --class other
  assert_contains "$HANDS_STDOUT" "local reason=fits class=other peak=2048MB local=7900MB" \
    "the other class must route by its own table peak"
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
  hands FM_REMOTE_HANDS=1 -- create --class suite --name t-badport --allow example.test:
  expect_code 2 "$HANDS_STATUS" "an allowance with an empty port must be refused"
  hands FM_REMOTE_HANDS=1 -- create --class suite --name t-badport --allow example.test:0
  expect_code 2 "$HANDS_STATUS" "port zero must be refused"
  hands FM_REMOTE_HANDS=1 -- create --class suite --name t-badport --allow example.test:99999
  expect_code 2 "$HANDS_STATUS" "a port above 65535 must be refused"
  hands FM_REMOTE_HANDS=1 -- create --class suite --name t-badport --allow :8443
  expect_code 2 "$HANDS_STATUS" "an empty host must be refused"
  reset_logs
  hands FM_REMOTE_HANDS=1 -- create --class suite --name t-hiport --allow example.test:65535 --expected-mins 60
  create_line=$(grep -F -- '--cloud create' "$SBX_LOG")
  assert_contains "$create_line" "--allow-network example.test:65535" "the highest valid port must be allowed"
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

# Execute the remote shell and its nested job shell; only sudo and tmux are
# stand-ins. tmux runs synchronously here to keep the portable test bounded;
# live smoke evidence separately proves detached job survival.
make_execution_tools() {
  mkdir -p "$TMP_ROOT/execbin"
  cat > "$TMP_ROOT/execbin/tmux" <<'SH'
#!/usr/bin/env bash
[ "$1 $2 $3 $4 $5 $6" = '-L fm-hands new-session -d -s fm-hands' ] || exit 91
printf '%s\n' "$1 $2 $3 $4 $5 $6" > "$FM_FAKE_TMUX_LOG"
shift 6
[ "$1" = bash ] || exit 92
shift
exec bash --noprofile --norc "$@"
SH
  cat > "$TMP_ROOT/execbin/sudo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_APT_LOG"
[ "$1" = apt-get ] || exit 93
exit "${FM_FAKE_APT_RC:-0}"
SH
  chmod +x "$TMP_ROOT/execbin/tmux" "$TMP_ROOT/execbin/sudo"
}

test_exec_preserves_literal_argv_and_job_exit() {
  make_home argv-home >/dev/null
  make_execution_tools
  reset_logs
  local saved_path=$ACTIVE_PATH
  ACTIVE_PATH="$TMP_ROOT/execbin:$ACTIVE_PATH"
  # Deliberately include empty, multiline, UTF-8, and shell-active arguments.
  # They must be emitted as bytes, never evaluated by either shell layer.
  # shellcheck disable=SC2016  # Expansion syntax is literal test input.
  local args=('' 'X=1 y' "one'quote" '"double"' '$HOME $(exit 89) `exit 90` ; *' $'line one\nline two' '航海 café' '--flag')
  printf '%s\0' "${args[@]}" > "$TMP_ROOT/expected-argv"
  # shellcheck disable=SC2016  # These variables expand inside the hosted job shell.
  hands FM_REMOTE_HANDS=1 FM_FAKE_SBX_EXECUTE=1 FM_FAKE_TMUX_LOG="$TMP_ROOT/tmux.log" -- \
    exec --name t-argv -- bash -c 'test "$LANG/$LC_ALL" = C.UTF-8/C.UTF-8 || exit 88
printf "%s\0" "$@"
exit 7' argv-fixture "${args[@]}"
  expect_code 0 "$HANDS_STATUS" "the preserved exec argv must actually launch the nested job shell"
  assert_grep '-L fm-hands new-session -d -s fm-hands' "$TMP_ROOT/tmux.log" \
    "the executing tmux fixture must receive the dedicated socket"
  cmp -s "$TMP_ROOT/expected-argv" "$TMP_ROOT/remote/fm-hands.log" \
    || fail "literal hosted argument bytes did not survive both shell layers"
  hands FM_REMOTE_HANDS=1 FM_FAKE_SBX_EXECUTE=1 -- wait --name t-argv --interval 1 --max-secs 2
  expect_code 7 "$HANDS_STATUS" "wait must read and propagate the actual nested shell's exit marker"
  assert_contains "$HANDS_STDOUT" 'exit=7' "the nested job exit must be reported"
  hands FM_REMOTE_HANDS=1 FM_FAKE_SBX_EXECUTE=1 FM_FAKE_TMUX_LOG="$TMP_ROOT/tmux.log" -- exec --name t-argv -- true
  expect_code 0 "$HANDS_STATUS" "a second job must launch after replacing the previous markers"
  hands FM_REMOTE_HANDS=1 FM_FAKE_SBX_EXECUTE=1 -- wait --name t-argv --interval 1 --max-secs 2
  expect_code 0 "$HANDS_STATUS" "a new successful job must replace the old exit=7 marker"
  [ ! -s "$TMP_ROOT/remote/fm-hands.log" ] || fail "the new true job must replace the old output"
  rm -f "$TMP_ROOT/remote/fm-hands.exit" "$TMP_ROOT/remote/fm-hands.log"
  ACTIVE_PATH=$saved_path
  pass "fm-remote-hands.sh: preserved argv executes literal arguments and records real job exits"
}

test_prepare_executes_bootstrap_and_literal_clone_arguments() {
  make_home prep-execute-home >/dev/null
  make_execution_tools
  reset_logs
  local repo="$TMP_ROOT/repo '航海" dest="$TMP_ROOT/clone '航海" saved_path=$ACTIVE_PATH
  git init -q "$repo" || fail "could not create the synthetic preparation source"
  git -C "$repo" checkout -qb fm/fixture || fail "could not create fixture branch"
  printf '%s\n' 'synthetic only' > "$repo/fixture.txt"
  git -C "$repo" add fixture.txt
  git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture \
    || fail "could not commit preparation fixture"
  ACTIVE_PATH="$TMP_ROOT/execbin:$ACTIVE_PATH"
  hands FM_REMOTE_HANDS=1 FM_FAKE_SBX_EXECUTE=1 FM_FAKE_APT_LOG="$TMP_ROOT/apt.log" -- \
    prepare --name t-prep-execute --repo "file://$repo" --branch fm/fixture --dest "$dest" --node-major 26
  expect_code 0 "$HANDS_STATUS" "prepare must execute its multiline bootstrap and real git clone"
  assert_contains "$HANDS_STDERR" 'already matches local major 26' "the executed node probe must retain the matching-major decision"
  assert_grep 'apt-get install -y -qq xz-utils tmux libatomic1 ruby gcc time' "$TMP_ROOT/apt.log" \
    "the required tmux bootstrap must actually reach apt's argv"
  cmp -s "$repo/fixture.txt" "$dest/fixture.txt" || fail "literal UTF-8/quoted clone paths did not reach git"
  [ "$(git -C "$repo" rev-parse HEAD)" = "$(git -C "$dest" rev-parse HEAD)" ] || fail "prepare did not clone the exact fixture head"
  [ "$(git -C "$dest" branch --show-current)" = fm/fixture ] || fail "the branch argument did not survive"
  hands FM_REMOTE_HANDS=1 FM_FAKE_SBX_EXECUTE=1 FM_FAKE_APT_LOG="$TMP_ROOT/apt.log" FM_FAKE_APT_RC=23 -- \
    prepare --name t-prep-fail --repo "file://$repo" --dest "$TMP_ROOT/never-cloned" --node-major 26
  expect_code 23 "$HANDS_STATUS" "prepare must propagate the actual bootstrap failure"
  assert_absent "$TMP_ROOT/never-cloned" "failed bootstrap must stop before clone"
  ACTIVE_PATH=$saved_path
  pass "fm-remote-hands.sh: prepare executes tmux bootstrap, node probe, and literal clone argv"
}

make_preparation_tools() {
  mkdir -p "$TMP_ROOT/prepbin" "$TMP_ROOT/node-install/bin" "$TMP_ROOT/node-release"
  cat > "$TMP_ROOT/node-install/bin/node" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 20.0.0
SH
  chmod +x "$TMP_ROOT/node-install/bin/node"
  local arch dir
  for arch in arm64 x64; do
    dir="node-v22.10.0-linux-$arch"
    mkdir -p "$TMP_ROOT/node-release/$dir/bin"
    cat > "$TMP_ROOT/node-release/$dir/bin/node" <<'SH'
#!/usr/bin/env bash
if [ "$1" = --version ]; then
  printf '%s\n' node >> "$FM_FAKE_PREP_LOG"
  [ "${FM_FAKE_PREP_FAIL:-}" != node ] || exit 31
  printf '%s\n' v22.10.0
else
  printf '%s\n' 22.10.0
fi
SH
    chmod +x "$TMP_ROOT/node-release/$dir/bin/node"
    tar -cJf "$TMP_ROOT/node-release/$dir.tar.xz" -C "$TMP_ROOT/node-release" "$dir" \
      || fail "could not build synthetic Node archive"
  done
  (cd "$TMP_ROOT/node-release" && sha256sum node-*.tar.xz) > "$TMP_ROOT/node-release/SHASUMS256.txt" \
    || fail "could not checksum synthetic Node archives"
  cat > "$TMP_ROOT/prepbin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$FM_FAKE_PREP_ARCH"
SH
  cat > "$TMP_ROOT/prepbin/curl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  */SHASUMS256.txt) stage=checksum-download ;;
  */) stage=index ;;
  *) stage=download ;;
esac
printf '%s\n' "$stage $*" >> "$FM_FAKE_PREP_LOG"
case "$stage" in
  index)
    printf '%s\n' node-v22.10.0-linux-arm64.tar.xz node-v22.10.0-linux-x64.tar.xz
    ;;
  checksum-download)
    if [ "${FM_FAKE_PREP_FAIL:-}" = checksum ]; then
      sed 's/^[0-9a-f]*/0000000000000000000000000000000000000000000000000000000000000000/' "$FM_FAKE_PREP_RELEASE/SHASUMS256.txt"
    else
      cat "$FM_FAKE_PREP_RELEASE/SHASUMS256.txt"
    fi
    ;;
  download)
    [ "${FM_FAKE_PREP_FAIL:-}" != download ] || exit 31
    [ "$1 $2" = '-fsSL -o' ] || exit 94
    cp "$FM_FAKE_PREP_RELEASE/${4##*/}" "$3" || exit 95
    ;;
esac
[ "${FM_FAKE_PREP_FAIL:-}" != "$stage" ] || exit 31
SH
  cat > "$TMP_ROOT/prepbin/sudo" <<'SH'
#!/usr/bin/env bash
case "$1" in
  apt-get) stage=$2 ;;
  tar) stage=extract ;;
  *) exit 93 ;;
esac
printf '%s\n' "$stage $*" >> "$FM_FAKE_PREP_LOG"
[ "${FM_FAKE_PREP_FAIL:-}" != "$stage" ] || exit 31
if [ "$stage" = extract ]; then
  [ "$2" = -xJf ] && [ "$4" = -C ] && [ "$5" = /usr/local ] && [ "$6" = --strip-components=1 ] || exit 96
  exec "$FM_FAKE_PREP_TAR" -xJf "$3" -C "$FM_FAKE_PREP_INSTALL" --strip-components=1
fi
SH
  cat > "$TMP_ROOT/prepbin/git" <<'SH'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$FM_FAKE_PREP_LOG"
if [ "${FM_FAKE_PREP_FAIL:-}" = clone ] && [ "$1" = clone ]; then
  "$FM_FAKE_PREP_GIT" "$@" || exit "$?"
  exit 31
fi
if [ "${FM_FAKE_PREP_FAIL:-}" = fetch ] && [ "$3" = fetch ]; then exit 31; fi
exec "$FM_FAKE_PREP_GIT" "$@"
SH
  chmod +x "$TMP_ROOT/prepbin/"*
}

prepare_fixture() {
  local dest=$1 arch=$2 failure=${3:-}
  : > "$TMP_ROOT/prep.log"
  hands FM_REMOTE_HANDS=1 FM_FAKE_SBX_EXECUTE=1 \
    FM_FAKE_PREP_ARCH="$arch" FM_FAKE_PREP_FAIL="$failure" \
    FM_FAKE_PREP_LOG="$TMP_ROOT/prep.log" FM_FAKE_PREP_RELEASE="$TMP_ROOT/node-release" \
    FM_FAKE_PREP_INSTALL="$TMP_ROOT/node-install" \
    FM_FAKE_PREP_TAR="$PREP_REAL_TAR" FM_FAKE_PREP_GIT="$PREP_REAL_GIT" -- \
    prepare --name t-node-prepare --repo "file://$TMP_ROOT/prep-source" --dest "$dest" --node-major 22
}

test_prepare_installs_node_and_stops_on_every_required_failure() {
  make_home prep-install-home >/dev/null
  local saved_path=$ACTIVE_PATH arch archive dest stage expected
  PREP_REAL_TAR=$(command -v tar)
  PREP_REAL_GIT=$(command -v git)
  git init -q "$TMP_ROOT/prep-source" || fail "could not create preparation source"
  printf '%s\n' fixture > "$TMP_ROOT/prep-source/fixture.txt"
  git -C "$TMP_ROOT/prep-source" add fixture.txt
  git -C "$TMP_ROOT/prep-source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture \
    || fail "could not commit preparation source"
  ACTIVE_PATH="$TMP_ROOT/node-install/bin:$TMP_ROOT/prepbin:$ACTIVE_PATH"
  for arch in aarch64 x86_64 arm64 x64; do
    make_preparation_tools
    dest="$TMP_ROOT/prep-$arch"
    prepare_fixture "$dest" "$arch"
    expect_code 0 "$HANDS_STATUS" "mismatched Node major must install and clone on $arch"
    case "$arch" in aarch64|arm64) archive=arm64 ;; *) archive=x64 ;; esac
    assert_grep "https://nodejs.org/dist/latest-v22.x/node-v22.10.0-linux-$archive.tar.xz" "$TMP_ROOT/prep.log" \
      "the download must use the published $archive archive"
    assert_contains "$HANDS_STDOUT" ': OK' "the downloaded archive must pass real checksum verification"
    assert_contains "$HANDS_STDOUT" 'v22.10.0' "the extracted Node must execute"
    cmp -s "$TMP_ROOT/prep-source/fixture.txt" "$dest/fixture.txt" || fail "Node installation did not proceed to clone"
  done
  for stage in update install index download checksum-download checksum extract node; do
    make_preparation_tools
    dest="$TMP_ROOT/failed-$stage"
    prepare_fixture "$dest" aarch64 "$stage"
    expected=31
    [ "$stage" != checksum ] || expected=1
    expect_code "$expected" "$HANDS_STATUS" "$stage failure must stop preparation"
    assert_absent "$dest" "$stage failure must stop before cloning"
    assert_no_grep 'git clone' "$TMP_ROOT/prep.log" "$stage failure must never invoke cloning"
    assert_not_contains "$HANDS_STDOUT" 'prepare: name=' "$stage failure must not report success"
    case "$stage" in
      checksum|checksum-download)
        assert_no_grep 'extract' "$TMP_ROOT/prep.log" "checksum failure must prevent extraction"
        ;;
      update)
        assert_no_grep 'install' "$TMP_ROOT/prep.log" "update failure must prevent installation"
        ;;
    esac
  done
  make_preparation_tools
  prepare_fixture "$TMP_ROOT/failed-clone" x86_64 clone
  expect_code 31 "$HANDS_STATUS" "a clone failure must propagate even when HEAD exists"
  assert_no_grep 'rev-parse HEAD' "$TMP_ROOT/prep.log" "clone failure must stop before the HEAD query"
  local shallow="$TMP_ROOT/prep-shallow"
  "$PREP_REAL_GIT" clone -q --depth 1 "file://$TMP_ROOT/prep-source" "$shallow" \
    || fail "could not create shallow preparation fixture"
  prepare_fixture "$shallow" x86_64 fetch
  expect_code 31 "$HANDS_STATUS" "unshallow failure must propagate despite a valid HEAD"
  [ -f "$shallow/.git/shallow" ] || fail "failed fetch must retain the shallow fixture"
  assert_no_grep 'rev-parse HEAD' "$TMP_ROOT/prep.log" "fetch failure must stop before the HEAD query"
  prepare_fixture "$shallow" x86_64
  expect_code 0 "$HANDS_STATUS" "an existing shallow clone must unshallow successfully"
  assert_absent "$shallow/.git/shallow" "successful preparation must leave a full clone"
  [ "$("$PREP_REAL_GIT" -C "$shallow" rev-parse HEAD)" = "$("$PREP_REAL_GIT" -C "$TMP_ROOT/prep-source" rev-parse HEAD)" ] \
    || fail "unshallow must retain the expected HEAD"
  prepare_fixture "$shallow" x86_64
  expect_code 0 "$HANDS_STATUS" "an existing full clone must prepare successfully"
  assert_no_grep 'fetch --unshallow' "$TMP_ROOT/prep.log" "a full clone must not fetch unnecessarily"
  ACTIVE_PATH=$saved_path
  pass "fm-remote-hands.sh: Node architecture mapping and every preparation failure execute correctly"
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

test_wait_keeps_polling_a_reachable_sandbox_with_no_marker_yet() {
  make_home wait-live-home >/dev/null
  reset_logs
  hands FM_REMOTE_HANDS=1 FM_FAKE_SBX_EXECUTE=1 -- wait --name t-live --interval 1 --max-secs 2
  expect_code 1 "$HANDS_STATUS" "a reachable sandbox with no marker yet must end on the wait bound"
  assert_contains "$HANDS_STDERR" "timed out after 2s" "the bound, not a false abort, must end the wait"
  assert_not_contains "$HANDS_STDERR" "unreachable" \
    "a reachable sandbox must never be diagnosed unreachable while its job runs"
  pass "fm-remote-hands.sh: wait keeps polling a reachable sandbox with no marker yet"
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

test_prepare_runs_exec_streams_under_the_prepare_bound() {
  make_home prep-bound-home >/dev/null
  reset_logs
  printf '22.22.1\n' > "$EXEC_SEQ"
  hands FM_REMOTE_HANDS=1 FM_FAKE_TIMEOUT_LOG="$TIMEOUT_LOG" -- prepare --name t-bound --repo https://github.com/kirkins/firstmate
  expect_code 0 "$HANDS_STATUS" "prepare must succeed while its bounds are recorded"
  assert_grep "60 sbx login --username $FAKE_DOCKER_ID --password-stdin" "$TIMEOUT_LOG" \
    "login must keep the control-plane bound"
  local exec_bounds
  exec_bounds=$(grep -c '^900 sbx --cloud exec' "$TIMEOUT_LOG")
  [ "$exec_bounds" -eq 3 ] \
    || fail "prepare's three exec streams must run under the 900s prepare bound (got $exec_bounds)"
  reset_logs
  printf '22.22.1\n' > "$EXEC_SEQ"
  hands FM_REMOTE_HANDS=1 FM_FAKE_TIMEOUT_LOG="$TIMEOUT_LOG" FM_REMOTE_HANDS_PREPARE_TIMEOUT=1200 -- prepare --name t-bound2 --repo https://github.com/kirkins/firstmate
  expect_code 0 "$HANDS_STATUS" "prepare must succeed under a raised prepare bound"
  assert_grep "1200 sbx --cloud exec" "$TIMEOUT_LOG" \
    "FM_REMOTE_HANDS_PREPARE_TIMEOUT must bound the exec streams"
  pass "fm-remote-hands.sh: prepare exec streams run under their own bound"
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

test_fake_exec_restores_fixture_path_after_login() {
  local real_bash out status
  real_bash=$(command -v bash)
  cat > "$TMP_ROOT/login-shell" <<SH
#!/usr/bin/env bash
export PATH="$COREBIN"
exec "$real_bash" -c "\$2"
SH
  cat > "$FAKEBIN/fixture-command" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$PATH" "$1"
SH
  chmod +x "$TMP_ROOT/login-shell" "$FAKEBIN/fixture-command"
  out=$(env PATH="$ACTIVE_PATH" FM_FAKE_SBX_EXECUTE=1 FM_FAKE_SBX_REMOTE_TMP="$TMP_ROOT/remote" "$FAKEBIN/sbx" \
    --cloud exec t-login -- "$TMP_ROOT/login-shell" -lc \
    'fixture-command "argument with spaces"' 2>"$TMP_ROOT/stderr"); status=$?
  expect_code 0 "$status" "fake exec must restore fixture commands after login changes PATH"
  [ "$out" = "$ACTIVE_PATH|argument with spaces" ] \
    || fail "fake exec must restore the complete fixture PATH and preserve payload quoting"
  pass "fm-remote-hands.sh: fake exec restores fixture PATH after login initialization"
}

test_prepare_verifies_downloaded_archive_before_extraction() {
  make_home prep-checksum-home >/dev/null
  local real_sha sha_args=() mode expected
  if real_sha=$(command -v sha256sum); then
    :
  elif real_sha=$(command -v shasum); then
    sha_args=(-a 256)
  else
    fail "checksum regression requires sha256sum or shasum"
  fi
  printf 'node archive fixture\n' > "$TMP_ROOT/node-archive"
  expected=$("$real_sha" ${sha_args[@]+"${sha_args[@]}"} "$TMP_ROOT/node-archive" | cut -d' ' -f1)
  mkdir -p "$TMP_ROOT/download"
  cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  */latest-v*.x/)
    printf '%s\n' 'node-v20.10.0-linux-x64.tar.xz'
    ;;
  *SHASUMS256.txt)
    case "$FM_FAKE_CHECKSUM_MODE" in
      missing) ;;
      wrong) printf '%064d  node-v20.10.0-linux-x64.tar.xz\n' 0 ;;
      *) printf '%s  node-v20.10.0-linux-x64.tar.xz\n' "$FM_FAKE_EXPECTED_SHA" ;;
    esac
    ;;
  *)
    [ "$2" = -o ] && [ -n "$3" ] || exit 1
    cp "$FM_FAKE_ARCHIVE" "$FM_FAKE_DOWNLOAD_DIR/${3##*/}"
    ;;
esac
SH
  cat > "$FAKEBIN/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' x64
SH
  cat > "$FAKEBIN/sudo" <<'SH'
#!/usr/bin/env bash
if [ "$1" = apt-get ]; then exit 0; fi
exec "$@"
SH
  cat > "$FAKEBIN/tar" <<'SH'
#!/usr/bin/env bash
[ "$1" = -xJf ] && [ -f "$FM_FAKE_DOWNLOAD_DIR/${2##*/}" ] || exit 1
printf 'extracted\n' >> "$FM_FAKE_EXTRACTION_LOG"
SH
  cat > "$FAKEBIN/sha256sum" <<SH
#!/usr/bin/env bash
if [ "\${FM_FAKE_CHECKSUM_MODE:-}" = verifier-error ]; then exit 9; fi
cd "\$FM_FAKE_DOWNLOAD_DIR" || exit 1
exec "$real_sha" ${sha_args[*]:-} "\$@"
SH
  cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
case "$1" in
  clone) exit 0 ;;
  -C) printf '%s\n' fake-head ;;
esac
SH
  chmod +x "$FAKEBIN/curl" "$FAKEBIN/uname" "$FAKEBIN/sudo" "$FAKEBIN/tar" "$FAKEBIN/sha256sum" "$FAKEBIN/git"
  for mode in good missing wrong verifier-error; do
    rm -f "$TMP_ROOT/extracted"
    : > "$EXEC_SEQ"
    printf '22.22.1\n' > "$EXEC_SEQ"
    : > "$EXEC_CALLS"
    hands FM_REMOTE_HANDS=1 FM_FAKE_SBX_EXECUTE=1 FM_FAKE_CHECKSUM_MODE="$mode" \
      FM_FAKE_EXPECTED_SHA="$expected" FM_FAKE_ARCHIVE="$TMP_ROOT/node-archive" \
      FM_FAKE_DOWNLOAD_DIR="$TMP_ROOT/download" \
      FM_FAKE_EXTRACTION_LOG="$TMP_ROOT/extracted" -- prepare --name t-checksum \
      --repo https://github.com/kirkins/firstmate --node-major 20
    if [ "$mode" = good ]; then
      expect_code 0 "$HANDS_STATUS" "a correct digest must permit extraction and prepare ($HANDS_STDERR)"
      [ -s "$TMP_ROOT/extracted" ] || fail "a correct digest must reach extraction (stderr: $HANDS_STDERR; sandbox: $(cat "$SBX_LOG"))"
    else
      [ "$HANDS_STATUS" -ne 0 ] || fail "$mode checksum must fail prepare"
      [ ! -e "$TMP_ROOT/extracted" ] || fail "$mode checksum must stop before extraction"
      assert_contains "$HANDS_STDERR" "checksum verification failed" "$mode checksum must explain the failure"
    fi
  done
  pass "fm-remote-hands.sh: prepare verifies the downloaded Node archive before extraction"
}

test_help_and_usage_plumbing
test_off_by_default_is_a_hard_noop
test_env_file_activation_and_env_wins
test_route_local_memory_decisions
test_route_reads_the_real_heavy_slot
test_create_sizes_shapes_ttl_and_allowances
test_exec_hosts_the_job_on_a_dedicated_tmux_socket
test_exec_preserves_literal_argv_and_job_exit
test_prepare_executes_bootstrap_and_literal_clone_arguments
test_prepare_installs_node_and_stops_on_every_required_failure
test_wait_propagates_the_hosted_exit_code
test_wait_keeps_polling_a_reachable_sandbox_with_no_marker_yet
test_copy_and_log_paths
test_teardown_removes_and_cleans_the_manifest
test_credentials_load_in_process_and_never_leak
test_missing_tools_fail_closed
test_prepare_pins_the_fidelity_recipe
test_prepare_runs_exec_streams_under_the_prepare_bound
test_prepare_without_local_node_pins_nothing_loudly
test_fake_exec_restores_fixture_path_after_login
test_prepare_verifies_downloaded_archive_before_extraction
