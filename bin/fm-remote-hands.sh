#!/usr/bin/env bash
# fm-remote-hands.sh - Docker Cloud Sandboxes driver and heavy-slot router.
#
# WHY. The local 8 GiB machine is the fleet's build bottleneck: its heavy-slot
# turnstile serializes memory-heavy jobs, and the shellcheck sweep's four
# heaviest roots peak at 5.5-6 GiB resident and survive locally only through
# zram+swap. The adopted lane (2026-10-11) is remote hands: a local agent
# drives a disposable cloud sandbox as a pure remote executor for heavy builds
# and tests, with no model and no provider credential ever running inside the
# sandbox. The live proof measured a Medium sandbox running the repo's whole
# behavior suite (247/253 scripts, herdr e2e real) and the sweep shape proven
# to be Large, at per-second compute pricing billed only while running.
#
# CONTRACT.
#   - Off by default: the lane is on only when FM_REMOTE_HANDS holds a truthy
#     value (1, on, true, yes, any case) from the environment or the home's
#     gitignored $FM_HOME/.env, env winning exactly like the forge-mail plane.
#     `route` on an off home prints `local reason=off` and exits 0 (a hard
#     no-op), every sandbox-creating command refuses naming the requirement,
#     and `enabled` prints `off` for other scripts (bin/fm-brief.sh). Only
#     `teardown` works while off, because removing a leftover sandbox is the
#     safety action, never a new one.
#   - Credentials stay in-process: DOCKER_ID and DOCKER_PAT are read live from
#     the cluster secret named by FM_REMOTE_HANDS_SECRET via kubectl, reach
#     `sbx login` only as --password-stdin, are never printed, logged, or
#     written anywhere by this script, and the sandbox itself is always the
#     bare `shell` agent with no provider credential set inside it: this
#     script never invokes `sbx secret set`. The sbx CLI's own login state is
#     pinned under $FM_HOME/state/remote-hands/sbx-config via XDG_CONFIG_HOME
#     so no machine-global config is touched.
#   - Sizing is per job class (the class table below): `suite` is the default
#     Medium shape (4 vCPU / 8 GiB) proven by the suite run, `sweep` is Large
#     (8 vCPU / 16 GiB) because anything including the shellcheck sweep needs
#     the 5.5-6 GiB worst-case roots without swap, and TTL is sized as the
#     expected wall time plus FM_REMOTE_HANDS_TTL_MARGIN percent (default 50),
#     clamped to the platform's 24 h ceiling. Creation always passes
#     --on-timeout delete so a forgotten sandbox cannot linger billed.
#   - Long jobs survive exec-stream teardown: `exec` launches the job inside
#     the sandbox under a daemonized tmux on the dedicated fm-hands socket
#     (never the default socket, which the suite's own tmux tests kill), the
#     exec stream returns immediately, and `wait` polls the exit marker. One
#     hosted job per sandbox: a later `exec` overwrites the marker paths.
#   - Environment fidelity: every in-sandbox script runs with
#     LANG=C.UTF-8 LC_ALL=C.UTF-8, `prepare` clones the full repository
#     (never --depth, and `git fetch --unshallow` when a shallow clone
#     exists), pins node to the local machine's major version (or
#     --node-major), verifying the nodejs.org tarball against SHASUMS256.txt,
#     and installs only the documented closed tool set. pi and zellij are
#     never installed: tool-absent classes are clean gate-skips by design.
#   - Routing: `route` never touches the cloud. It reads the machine's heavy
#     slot through bin/fm-heavy-slot.sh's public `status` (no file parsing, no
#     semantics change there) and the local RAM, then prints one decision
#     line: the sandbox when the class's peak estimate exceeds 70 percent of
#     local RAM (oversized) or another live task holds the heavy slot
#     (slot-held, unless --task names that holder), otherwise local. A job
#     routed to the sandbox takes no local heavy slot at all.
#   - Manifests: create records the sandbox in
#     $FM_HOME/state/remote-hands/<name>.rec for crash recovery and teardown
#     removes it; `sbx --cloud ls` stays the authoritative live list.
#
# Usage:
#   fm-remote-hands.sh enabled
#       Print `on` or `off` for the configured lane; no cloud, no state.
#   fm-remote-hands.sh route --class <suite|sweep|other> [--task <id>]
#       Print the routing decision for one heavy job class: `local reason=off`
#       on an unconfigured home, `local reason=fits class=<c> peak=<MB>
#       local=<MB>`, or `sandbox shape=<medium|large> class=<c>
#       reason=<oversized|slot-held> [holder=<id>] peak=<MB> local=<MB>`.
#       Classes: suite (behavior-suite runs, Medium), sweep (anything that
#       includes the shellcheck sweep, Large), other (default Medium). Route
#       decides only; it never creates a sandbox.
#   fm-remote-hands.sh create --class <class> --name <name>
#                           [--expected-mins <m>] [--allow <host:port>]...
#       Log in from the cluster secret, then create the sized sandbox with
#       --on-timeout delete, the default network allowance set (github.com and
#       GitHub's release/raw CDNs, nodejs.org, the npm registry, and Ubuntu's
#       apt ports, all sandbox-scoped), plus any --allow extras, and the bare
#       shell agent, then record the manifest. --expected-mins defaults to the
#       class default (suite 120, sweep 150, other 60).
#   fm-remote-hands.sh prepare --name <name> --repo <url> [--branch <b>]
#                             [--node-major <v>] [--dest <dir>]
#       Bring one sandbox up to the local fidelity baseline: apt tools
#       (xz-utils tmux libatomic1 ruby gcc time), node pinned to the local
#       machine's major (skipped loudly when neither local node nor
#       --node-major can name one), and a full clone of --repo (default
#       destination /home/agent/workspace/<repo>). SHA-pinned lint builds are
#       uploaded, not installed: produce them locally with the repo's pinned
#       installers and `copy-in` them, then put them on the sandbox PATH.
#   fm-remote-hands.sh exec --name <name> -- <command...>
#       Launch one long job on the sandbox's fm-hands tmux socket with the
#       UTF-8 locale pinned; the job's combined output lands in
#       /tmp/fm-hands.log and its exit code in /tmp/fm-hands.exit. Returns
#       immediately after launching.
#   fm-remote-hands.sh wait --name <name> [--interval <s>] [--max-secs <s>]
#       Poll the exit marker until the hosted job finishes, then print
#       `exit=<n>` and exit with the job's own exit code. Three consecutive
#       unreachable polls abort naming the sandbox; --max-secs (default 86400)
#       bounds the wait.
#   fm-remote-hands.sh log --name <name> [--out <file>]
#       Copy the hosted job's /tmp/fm-hands.log out (default
#       ./fm-hands-<name>.log) and print the destination path.
#   fm-remote-hands.sh copy-in --name <name> <local-path> [<remote-dest>]
#       Copy one file into the sandbox (default destination
#       /home/agent/workspace/).
#   fm-remote-hands.sh copy-out --name <name> <remote-path> <local-dest>
#       Copy one artifact out of the sandbox.
#   fm-remote-hands.sh teardown --name <name>
#       Remove the sandbox with --force and delete its manifest; works while
#       the lane is off. Idempotent about the manifest, never about billing:
#       teardown is the only place this script deletes anything.
#
# Configuration, from the environment or the home's .env (env wins; this
# section cross-references docs/configuration.md "Remote hands", the schema
# owner):
#   FM_REMOTE_HANDS=                # truthy switches the lane on; default off
#   FM_REMOTE_HANDS_SECRET=opencode/opencode-docker-cloud
#                                    # <namespace>/<secret> holding DOCKER_ID
#                                    # and DOCKER_PAT
#   FM_REMOTE_HANDS_TTL_MARGIN=50   # percent over expected wall; valid 10..300
#   FM_REMOTE_HANDS_TIMEOUT=60      # seconds bounding each sbx control-plane
#                                    # call; 10..3600
#   FM_REMOTE_HANDS_PREPARE_TIMEOUT=900
#                                    # seconds bounding prepare's exec streams
#                                    # (node probe, apt, clone); 10..3600
#
# Exit codes: 0 ok (including every decided `route` line and a propagated job
# exit of 0), the hosted job's own nonzero exit code from `wait`, 1 failure
# (missing sbx/kubectl/credential, unreachable sandbox, wait timeout), 2
# usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

FM_HOME="${FM_HOME:-}"
if [ -z "$FM_HOME" ]; then
  FM_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
ENV_FILE="$FM_HOME/.env"

# Fill each config key from .env only when the environment left it unset, the
# same env-wins contract the Relay and forge-mail planes use.
FM_REMOTE_HANDS="${FM_REMOTE_HANDS:-$(fmx_env_get FM_REMOTE_HANDS "$ENV_FILE")}"
FM_REMOTE_HANDS_SECRET="${FM_REMOTE_HANDS_SECRET:-$(fmx_env_get FM_REMOTE_HANDS_SECRET "$ENV_FILE")}"
FM_REMOTE_HANDS_TTL_MARGIN="${FM_REMOTE_HANDS_TTL_MARGIN:-$(fmx_env_get FM_REMOTE_HANDS_TTL_MARGIN "$ENV_FILE")}"
FM_REMOTE_HANDS_TIMEOUT="${FM_REMOTE_HANDS_TIMEOUT:-$(fmx_env_get FM_REMOTE_HANDS_TIMEOUT "$ENV_FILE")}"
FM_REMOTE_HANDS_PREPARE_TIMEOUT="${FM_REMOTE_HANDS_PREPARE_TIMEOUT:-$(fmx_env_get FM_REMOTE_HANDS_PREPARE_TIMEOUT "$ENV_FILE")}"
FM_REMOTE_HANDS_SECRET=${FM_REMOTE_HANDS_SECRET:-opencode/opencode-docker-cloud}
case "${FM_REMOTE_HANDS_TTL_MARGIN:-}" in
  ''|*[!0-9]*) FM_REMOTE_HANDS_TTL_MARGIN=50 ;;
esac
if [ "$FM_REMOTE_HANDS_TTL_MARGIN" -lt 10 ] || [ "$FM_REMOTE_HANDS_TTL_MARGIN" -gt 300 ]; then
  echo "note: FM_REMOTE_HANDS_TTL_MARGIN='$FM_REMOTE_HANDS_TTL_MARGIN' is outside 10..300; using 50" >&2
  FM_REMOTE_HANDS_TTL_MARGIN=50
fi
case "${FM_REMOTE_HANDS_TIMEOUT:-}" in
  ''|*[!0-9]*) FM_REMOTE_HANDS_TIMEOUT=60 ;;
esac
if [ "$FM_REMOTE_HANDS_TIMEOUT" -lt 10 ] || [ "$FM_REMOTE_HANDS_TIMEOUT" -gt 3600 ]; then
  echo "note: FM_REMOTE_HANDS_TIMEOUT='$FM_REMOTE_HANDS_TIMEOUT' is outside 10..3600; using 60" >&2
  FM_REMOTE_HANDS_TIMEOUT=60
fi
case "${FM_REMOTE_HANDS_PREPARE_TIMEOUT:-}" in
  ''|*[!0-9]*) FM_REMOTE_HANDS_PREPARE_TIMEOUT=900 ;;
esac
if [ "$FM_REMOTE_HANDS_PREPARE_TIMEOUT" -lt 10 ] || [ "$FM_REMOTE_HANDS_PREPARE_TIMEOUT" -gt 3600 ]; then
  echo "note: FM_REMOTE_HANDS_PREPARE_TIMEOUT='$FM_REMOTE_HANDS_PREPARE_TIMEOUT' is outside 10..3600; using 900" >&2
  FM_REMOTE_HANDS_PREPARE_TIMEOUT=900
fi

HANDS_STATE="$FM_HOME/state/remote-hands"
MANIFEST_DIR="$HANDS_STATE"
SBX_SOCKET=fm-hands
JOB_LOG=/tmp/fm-hands.log
JOB_EXIT=/tmp/fm-hands.exit
REMOTE_HOME=/home/agent
DEFAULT_DEST_DIR=$REMOTE_HOME/workspace
# Sandbox-scoped network allowances, in a stable order: GitHub itself plus the
# release/raw CDNs the pinned lint builds and the no-mistakes verifier fetch
# need, nodejs.org for the pinned node major, the public npm registry, and
# Ubuntu's apt ports for the prepare recipe's tool installs. Everything else
# stays denied by the sandbox's default policy.
DEFAULT_ALLOWANCES=(
  github.com:443
  release-assets.githubusercontent.com:443
  raw.githubusercontent.com:443
  nodejs.org:443
  registry.npmjs.org:443
  ports.ubuntu.com:443
  ports.ubuntu.com:80
)
# Class table: name -> sandbox shape, peak local RAM estimate in MB (the
# routing input), and default expected wall minutes for TTL sizing. suite is
# the Medium-proven behavior-suite run; sweep covers anything that includes
# the shellcheck sweep, whose four heaviest roots peak at 5.5-6 GiB resident
# and OOM-kill on a swapless 8 GiB VM; other is the Medium default for
# unclassified heavy jobs.
REMOTE_HANDS_CLASSES='suite sweep other'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

remote_hands_enabled() {
  case "$(printf '%s' "${FM_REMOTE_HANDS:-}" | tr '[:upper:]' '[:lower:]')" in
    1|on|true|yes) return 0 ;;
    *) return 1 ;;
  esac
}

remote_hands_require_enabled() {
  if ! remote_hands_enabled; then
    echo "error: the remote-hands lane is off; set FM_REMOTE_HANDS (for example FM_REMOTE_HANDS=1) in the environment or $ENV_FILE to use this command" >&2
    exit 1
  fi
}

remote_hands_valid_id() {
  case "${1:-}" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

remote_hands_valid_positive_int() {
  case "${1:-}" in
    '' | 0 | 0[0-9]* | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

remote_hands_valid_endpoint() {
  local port
  case "${1:-}" in
    '' | *[!A-Za-z0-9.:-]*) return 1 ;;
    *[!A-Za-z0-9.-]*:*) return 1 ;;
    *:*[!0-9]* | *: | :* | *:[0-9][0-9][0-9][0-9][0-9][0-9]*) return 1 ;;
    *:*) ;;
    *) return 1 ;;
  esac
  port=${1##*:}
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

remote_hands_valid_class() {
  case "${1:-}" in
    suite|sweep|other) return 0 ;;
    *) return 1 ;;
  esac
}

remote_hands_class_shape() {
  case "$1" in
    suite|other) printf 'medium\n' ;;
    sweep) printf 'large\n' ;;
  esac
}

remote_hands_class_peak() {
  case "$1" in
    suite) printf '4096\n' ;;
    sweep) printf '6144\n' ;;
    other) printf '2048\n' ;;
  esac
}

remote_hands_class_default_mins() {
  case "$1" in
    suite) printf '120\n' ;;
    sweep) printf '150\n' ;;
    other) printf '60\n' ;;
  esac
}

remote_hands_shape_cpus() {
  case "$1" in
    medium) printf '4\n' ;;
    large) printf '8\n' ;;
  esac
}

remote_hands_shape_memory() {
  case "$1" in
    medium) printf '8g\n' ;;
    large) printf '16g\n' ;;
  esac
}

# TTL string: whole hours as Nh (the documented form), otherwise Nm, clamped
# to the 24 h platform ceiling with a loud note when the margin overshot it.
remote_hands_ttl_string() {
  local mins=$1
  if [ "$mins" -gt 1440 ]; then
    echo "note: computed TTL ${mins}m exceeds the platform's 24 h ceiling; clamping to 1440m (extend later only within 24 h of creation)" >&2
    mins=1440
  fi
  if [ $(( mins % 60 )) -eq 0 ]; then
    printf '%sh\n' $(( mins / 60 ))
  else
    printf '%sm\n' "$mins"
  fi
}

# Single-quote shell quoting, the same shape bin/fm-heavy-slot.sh uses.
remote_hands_q() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# Local RAM in MB. The FM_TEST_SEAM-pinned override exists so behavior tests
# can pin the machine size deterministically; production always detects.
remote_hands_local_mem_mb() {
  local mem_kb mem_bytes
  if [ "${FM_TEST_SEAM:-0}" = 1 ] && remote_hands_valid_positive_int "${FM_REMOTE_HANDS_LOCAL_MEM_MB:-}"; then
    printf '%s\n' "$FM_REMOTE_HANDS_LOCAL_MEM_MB"
    return 0
  fi
  if [ -r /proc/meminfo ]; then
    mem_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
    if remote_hands_valid_positive_int "${mem_kb:-}"; then
      printf '%s\n' $(( mem_kb / 1024 ))
      return 0
    fi
  fi
  mem_bytes=$(sysctl -n hw.memsize 2>/dev/null) || mem_bytes=
  if remote_hands_valid_positive_int "${mem_bytes:-}"; then
    printf '%s\n' $(( mem_bytes / 1048576 ))
    return 0
  fi
  echo "error: cannot read local RAM (tried /proc/meminfo and sysctl hw.memsize); set FM_REMOTE_HANDS_LOCAL_MEM_MB under FM_TEST_SEAM to pin it" >&2
  return 1
}

# One decoded value from the configured cluster secret, or empty. Never
# prints a diagnostic that includes the value.
remote_hands_secret_value() {
  local ns=$1 secret=$2 key=$3 encoded decoded
  encoded=$(kubectl -n "$ns" get secret "$secret" -o "jsonpath={.data.$key}" 2>/dev/null) || encoded=
  [ -n "$encoded" ] || return 0
  decoded=$(printf '%s' "$encoded" | base64 -d 2>/dev/null) || decoded=
  if [ -z "$decoded" ]; then
    decoded=$(printf '%s' "$encoded" | base64 -D 2>/dev/null) || decoded=
  fi
  printf '%s' "$decoded"
}

# Run one bounded sbx call: FM_REMOTE_HANDS_TIMEOUT bounds control-plane
# calls; a caller with long exec streams (prepare) raises the bound by setting
# REMOTE_HANDS_CALL_TIMEOUT before its execs.
remote_hands_sbx() {
  local secs=${REMOTE_HANDS_CALL_TIMEOUT:-$FM_REMOTE_HANDS_TIMEOUT}
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" sbx "$@"
  else
    sbx "$@"
  fi
}

# Load credentials in-process and sign in. The id reaches sbx as a --username
# argument (it is a login name, not a secret); the PAT only ever crosses stdin.
remote_hands_login() {
  local ns secret
  command -v kubectl >/dev/null 2>&1 \
    || { echo "error: kubectl is required to read the Docker credentials from cluster secret '$FM_REMOTE_HANDS_SECRET' but is not on PATH" >&2; exit 1; }
  command -v sbx >/dev/null 2>&1 \
    || { echo "error: the sbx CLI (>= 0.45.0, docs.docker.com/ai/sandboxes/install/) is required but is not on PATH" >&2; exit 1; }
  case "$FM_REMOTE_HANDS_SECRET" in
    */*) ns=${FM_REMOTE_HANDS_SECRET%/*}; secret=${FM_REMOTE_HANDS_SECRET#*/} ;;
    *)
      echo "error: FM_REMOTE_HANDS_SECRET='$FM_REMOTE_HANDS_SECRET' must be <namespace>/<secret>" >&2
      exit 2
      ;;
  esac
  DOCKER_ID=$(remote_hands_secret_value "$ns" "$secret" DOCKER_ID)
  DOCKER_PAT=$(remote_hands_secret_value "$ns" "$secret" DOCKER_PAT)
  if [ -z "${DOCKER_ID:-}" ] || [ -z "${DOCKER_PAT:-}" ]; then
    echo "error: cluster secret '$FM_REMOTE_HANDS_SECRET' did not provide both DOCKER_ID and DOCKER_PAT" >&2
    exit 1
  fi
  printf '%s' "$DOCKER_PAT" | remote_hands_sbx login --username "$DOCKER_ID" --password-stdin >/dev/null \
    || { echo "error: sbx login failed against the credentials from cluster secret '$FM_REMOTE_HANDS_SECRET'" >&2; exit 1; }
}

# Run one short script inside the sandbox under the fidelity locale. sbx
# exec joins the post-`--` words and re-evaluates them through the remote
# shell, so the script must travel as one single-quoted argument - the exact
# shape the live proof ran end to end
# (data/docker-sandboxes-first-proof-20261011/report.md, section 5).
remote_hands_run() {
  local name=$1 script=$2
  remote_hands_sbx --cloud exec "$name" -- bash -lc "$(remote_hands_q "$script")"
}

remote_hands_manifest_path() {
  printf '%s/%s.rec' "$MANIFEST_DIR" "$1"
}

remote_hands_manifest_write() {
  local name=$1 tmp
  mkdir -p -- "$MANIFEST_DIR"
  tmp=$(mktemp "$MANIFEST_DIR/.$name.tmp.XXXXXX")
  {
    printf 'name=%s\n' "$name"
    printf 'class=%s\n' "$2"
    printf 'shape=%s\n' "$3"
    printf 'cpus=%s\n' "$4"
    printf 'memory=%s\n' "$5"
    printf 'ttl=%s\n' "$6"
    printf 'created=%s\n' "$(date +%s)"
  } > "$tmp"
  mv -f -- "$tmp" "$(remote_hands_manifest_path "$name")"
}

# Pin the sbx CLI's own state inside the home's private state so no
# machine-global config is touched and no credential lands outside the home.
remote_hands_pin_sbx_state() {
  mkdir -p -- "$HANDS_STATE/sbx-config"
  export XDG_CONFIG_HOME="$HANDS_STATE/sbx-config"
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  enabled|route|create|prepare|exec|wait|log|copy-in|copy-out|teardown)
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

# --- enabled ---------------------------------------------------------------
if [ "$CMD" = enabled ]; then
  [ "$#" -eq 0 ] || { usage; exit 2; }
  if remote_hands_enabled; then
    printf 'on\n'
  else
    printf 'off\n'
  fi
  exit 0
fi

# --- shared argument parsing -----------------------------------------------
NAME=
CLASS=
TASK=
EXPECTED_MINS=
ALLOW_EXTRA=()
REPO=
BRANCH=
NODE_MAJOR=
DEST=
INTERVAL=30
MAX_SECS=86400
OUT=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name|--class|--task|--expected-mins|--allow|--repo|--branch|--node-major|--dest|--interval|--max-secs|--out)
      [ "$#" -ge 2 ] || { echo "error: $1 requires a value" >&2; usage; exit 2; }
      case "$1" in
        --name) NAME=${2:-} ;;
        --class) CLASS=${2:-} ;;
        --task) TASK=${2:-} ;;
        --expected-mins) EXPECTED_MINS=${2:-} ;;
        --allow) ALLOW_EXTRA+=("${2:-}") ;;
        --repo) REPO=${2:-} ;;
        --branch) BRANCH=${2:-} ;;
        --node-major) NODE_MAJOR=${2:-} ;;
        --dest) DEST=${2:-} ;;
        --interval) INTERVAL=${2:-} ;;
        --max-secs) MAX_SECS=${2:-} ;;
        --out) OUT=${2:-} ;;
      esac
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      # The first non-flag word ends flag parsing: exec takes the remaining
      # words as the hosted command, and copy-in/copy-out take them as their
      # positional paths.
      break
      ;;
  esac
done

if [ "$CMD" = route ]; then
  remote_hands_valid_class "$CLASS" || { echo "error: --class must be one of: $REMOTE_HANDS_CLASSES (got '${CLASS:-none}')" >&2; exit 2; }
  if [ -n "$TASK" ]; then
    remote_hands_valid_id "$TASK" || { echo "error: --task requires a task id (got '$TASK')" >&2; exit 2; }
  fi
else
  remote_hands_valid_id "$NAME" || { echo "error: --name requires a sandbox name (got '${NAME:-none}')" >&2; exit 2; }
fi

case "$CMD" in
  create|prepare|route|wait|log|teardown)
    [ "$#" -eq 0 ] || { echo "error: $CMD takes no positional arguments (got '$1'; flags come first)" >&2; exit 2; }
    ;;
esac

# --- route -----------------------------------------------------------------
if [ "$CMD" = route ]; then
  if ! remote_hands_enabled; then
    printf 'local reason=off\n'
    exit 0
  fi
  PEAK=$(remote_hands_class_peak "$CLASS")
  LOCAL_MEM=$(remote_hands_local_mem_mb)
  SHAPE=$(remote_hands_class_shape "$CLASS")
  if [ $(( PEAK * 10 )) -gt $(( LOCAL_MEM * 7 )) ]; then
    printf 'sandbox shape=%s class=%s reason=oversized peak=%sMB local=%sMB\n' \
      "$SHAPE" "$CLASS" "$PEAK" "$LOCAL_MEM"
    exit 0
  fi
  SLOT_STATUS_OUT=$("$SCRIPT_DIR/fm-heavy-slot.sh" status 2>/dev/null) || SLOT_STATUS_OUT=
  HOLDER=$(printf '%s\n' "$SLOT_STATUS_OUT" | tr ' ' '\n' | sed -n 's/^task=//p' | head -n1)
  SLOT_STATE=$(printf '%s\n' "$SLOT_STATUS_OUT" | tr ' ' '\n' | sed -n 's/^state=//p' | head -n1)
  if [ "$SLOT_STATE" = live ] && [ -n "$HOLDER" ] && [ "$HOLDER" != "${TASK:-}" ]; then
    printf 'sandbox shape=%s class=%s reason=slot-held holder=%s peak=%sMB local=%sMB\n' \
      "$SHAPE" "$CLASS" "$HOLDER" "$PEAK" "$LOCAL_MEM"
    exit 0
  fi
  printf 'local reason=fits class=%s peak=%sMB local=%sMB\n' "$CLASS" "$PEAK" "$LOCAL_MEM"
  exit 0
fi

# --- create ----------------------------------------------------------------
if [ "$CMD" = create ]; then
  remote_hands_require_enabled
  remote_hands_valid_class "$CLASS" || { echo "error: --class must be one of: $REMOTE_HANDS_CLASSES (got '${CLASS:-none}')" >&2; exit 2; }
  EXPECTED=${EXPECTED_MINS:-$(remote_hands_class_default_mins "$CLASS")}
  remote_hands_valid_positive_int "$EXPECTED" \
    || { echo "error: --expected-mins requires a positive integer minutes value (got '${EXPECTED_MINS:-none}')" >&2; exit 2; }
  TTL_MINS=$(( ( EXPECTED * ( 100 + FM_REMOTE_HANDS_TTL_MARGIN ) + 99 ) / 100 ))
  TTL=$(remote_hands_ttl_string "$TTL_MINS")
  SHAPE=$(remote_hands_class_shape "$CLASS")
  CPUS=$(remote_hands_shape_cpus "$SHAPE")
  MEMORY=$(remote_hands_shape_memory "$SHAPE")
  ALLOWANCES=("${DEFAULT_ALLOWANCES[@]}")
  for endpoint in ${ALLOW_EXTRA[@]+"${ALLOW_EXTRA[@]}"}; do
    remote_hands_valid_endpoint "$endpoint" \
      || { echo "error: --allow requires a <host>:<port> value (got '$endpoint')" >&2; exit 2; }
    ALLOWANCES+=("$endpoint")
  done
  remote_hands_pin_sbx_state
  remote_hands_login
  CREATE_ARGS=(--cloud create --name "$NAME" --cpus "$CPUS" --memory "$MEMORY" --ttl "$TTL" --on-timeout delete)
  for endpoint in "${ALLOWANCES[@]}"; do
    CREATE_ARGS+=(--allow-network "$endpoint")
  done
  CREATE_ARGS+=(shell)
  remote_hands_sbx "${CREATE_ARGS[@]}"
  remote_hands_manifest_write "$NAME" "$CLASS" "$SHAPE" "$CPUS" "$MEMORY" "$TTL"
  printf 'created: name=%s class=%s shape=%s cpus=%s memory=%s ttl=%s\n' \
    "$NAME" "$CLASS" "$SHAPE" "$CPUS" "$MEMORY" "$TTL"
  exit 0
fi

# --- prepare ---------------------------------------------------------------
if [ "$CMD" = prepare ]; then
  remote_hands_require_enabled
  [ -n "$REPO" ] || { echo "error: prepare requires --repo <url>" >&2; exit 2; }
  case "$REPO" in
    *:/*) ;;
    *)
      echo "error: --repo must be a git URL (got '$REPO')" >&2
      exit 2
      ;;
  esac
  if [ -n "$NODE_MAJOR" ]; then
    remote_hands_valid_positive_int "$NODE_MAJOR" \
      || { echo "error: --node-major requires a positive integer major version (got '$NODE_MAJOR')" >&2; exit 2; }
  fi
  DEST=${DEST:-$DEFAULT_DEST_DIR/$(printf '%s' "$REPO" | sed 's:/*$::;s:\.git$::;s:.*/::')}
  remote_hands_pin_sbx_state
  remote_hands_login
  REMOTE_HANDS_CALL_TIMEOUT=$FM_REMOTE_HANDS_PREPARE_TIMEOUT
  SANDBOX_NODE=$(remote_hands_run "$NAME" 'node -p process.versions.node 2>/dev/null || true' 2>/dev/null) || SANDBOX_NODE=
  LOCAL_NODE_MAJOR=$NODE_MAJOR
  if [ -z "$LOCAL_NODE_MAJOR" ]; then
    if command -v node >/dev/null 2>&1; then
      LOCAL_NODE_MAJOR=$(node -p process.versions.node 2>/dev/null | cut -d. -f1)
    fi
  fi
  remote_hands_valid_positive_int "${LOCAL_NODE_MAJOR:-}" || LOCAL_NODE_MAJOR=
  # shellcheck disable=SC2016  # $-expansions in this script run in the sandbox shell, not here.
  APT_AND_NODE_SCRIPT='export LANG=C.UTF-8 LC_ALL=C.UTF-8
sudo apt-get update -qq && sudo apt-get install -y -qq xz-utils tmux libatomic1 ruby gcc time'
  SANDBOX_MAJOR=$(printf '%s' "$SANDBOX_NODE" | cut -d. -f1)
  if [ -n "$LOCAL_NODE_MAJOR" ] && [ "$SANDBOX_MAJOR" != "$LOCAL_NODE_MAJOR" ]; then
    echo "prepare: sandbox node '$(printf '%s' "$SANDBOX_NODE" | tr -d '[:space:]')' -> local major $LOCAL_NODE_MAJOR; installing from nodejs.org" >&2
    # shellcheck disable=SC2016  # $-expansions in the appended script run in the sandbox shell.
    APT_AND_NODE_SCRIPT="$APT_AND_NODE_SCRIPT"'
arch=$(uname -m)
base="https://nodejs.org/dist/latest-v'"$LOCAL_NODE_MAJOR"'.x"
file=$(curl -fsSL "$base/" | grep -oE "node-v[0-9]+\.[0-9]+\.[0-9]+-linux-${arch}\.tar\.xz" | head -n 1)
[ -n "$file" ] || { echo "node tarball not found under $base" >&2; exit 1; }
curl -fsSL -o /tmp/fm-node.tar.xz "$base/$file"
(cd /tmp && curl -fsSL "$base/SHASUMS256.txt" | grep -F " $file" | sha256sum -c -)
sudo tar -xJf /tmp/fm-node.tar.xz -C /usr/local --strip-components=1
hash -r
node --version'
  elif [ -z "$LOCAL_NODE_MAJOR" ]; then
    echo "prepare: no local node and no --node-major; leaving the sandbox node version as is" >&2
  else
    echo "prepare: sandbox node $(printf '%s' "$SANDBOX_NODE" | tr -d '[:space:]') already matches local major $LOCAL_NODE_MAJOR" >&2
  fi
  # shellcheck disable=SC2016  # The clone script's $dest expands in the sandbox shell, not here.
  CLONE_SCRIPT='export LANG=C.UTF-8 LC_ALL=C.UTF-8
dest='"$(remote_hands_q "$DEST")"'
if [ -d "$dest/.git" ]; then
  if [ -f "$dest/.git/shallow" ]; then git -C "$dest" fetch --unshallow; fi
else
  git clone'"$( [ -z "$BRANCH" ] || printf ' --branch %s' "$(remote_hands_q "$BRANCH")" )"' '"$(remote_hands_q "$REPO")"' "$dest"
fi
git -C "$dest" rev-parse HEAD'
  remote_hands_run "$NAME" "$APT_AND_NODE_SCRIPT"
  remote_hands_run "$NAME" "$CLONE_SCRIPT"
  printf 'prepare: name=%s repo=%s dest=%s\n' "$NAME" "$REPO" "$DEST"
  exit 0
fi

# --- exec ------------------------------------------------------------------
if [ "$CMD" = exec ]; then
  remote_hands_require_enabled
  [ "$#" -ge 1 ] || { echo "error: exec requires a command after --" >&2; exit 2; }
  CMD_STR=
  for word in "$@"; do
    if [ -n "$CMD_STR" ]; then
      CMD_STR="$CMD_STR "
    fi
    CMD_STR="$CMD_STR$(remote_hands_q "$word")"
  done
  # shellcheck disable=SC2016  # $? is captured by the sandbox shell, not here.
  JOB_SCRIPT='export LANG=C.UTF-8 LC_ALL=C.UTF-8
('"$CMD_STR"') > '"$JOB_LOG"' 2>&1
printf "%s\n" "$?" > '"$JOB_EXIT"
  LAUNCH='rm -f '"$JOB_LOG"' '"$JOB_EXIT"'
tmux -L '"$SBX_SOCKET"' new-session -d -s '"$SBX_SOCKET"' bash -lc '"$(remote_hands_q "$JOB_SCRIPT")"
  # Same proof-pinned exec shape as remote_hands_run: one single-quoted
  # payload re-evaluated by the joining remote shell.
  remote_hands_pin_sbx_state
  remote_hands_login
  remote_hands_sbx --cloud exec "$NAME" -- bash -lc "$(remote_hands_q "$LAUNCH")"
  printf 'launched: name=%s socket=%s log=%s exit=%s\n' "$NAME" "$SBX_SOCKET" "$JOB_LOG" "$JOB_EXIT"
  exit 0
fi

# --- wait ------------------------------------------------------------------
if [ "$CMD" = wait ]; then
  remote_hands_require_enabled
  remote_hands_valid_positive_int "$INTERVAL" || { echo "error: --interval requires a positive integer seconds value (got '$INTERVAL')" >&2; exit 2; }
  remote_hands_valid_positive_int "$MAX_SECS" || { echo "error: --max-secs requires a positive integer seconds value (got '$MAX_SECS')" >&2; exit 2; }
  remote_hands_pin_sbx_state
  remote_hands_login
  MARKER_SCRIPT='cat '"$JOB_EXIT"' 2>/dev/null || true'
  START=$(date +%s)
  DEADLINE=$(( START + MAX_SECS ))
  FAILS=0
  while :; do
    MARKER=
    if MARKER=$(remote_hands_run "$NAME" "$MARKER_SCRIPT" 2>/dev/null); then
      FAILS=0
      MARKER=$(printf '%s' "$MARKER" | tr -d '[:space:]')
      case "$MARKER" in
        ''|*[!0-9]*) ;;
        *)
          printf 'exit=%s\n' "$MARKER"
          exit "$MARKER"
          ;;
      esac
    else
      FAILS=$(( FAILS + 1 ))
      if [ "$FAILS" -ge 3 ]; then
        echo "error: sandbox '$NAME' unreachable across $FAILS consecutive polls; run 'sbx --cloud ls' to see whether the TTL deleted it" >&2
        exit 1
      fi
    fi
    NOW=$(date +%s)
    if [ "$NOW" -ge "$DEADLINE" ]; then
      echo "error: wait timed out after ${MAX_SECS}s without an exit marker; the job may still be running under the $SBX_SOCKET tmux socket" >&2
      exit 1
    fi
    sleep "$INTERVAL"
  done
fi

# --- log -------------------------------------------------------------------
if [ "$CMD" = log ]; then
  remote_hands_require_enabled
  OUT=${OUT:-./fm-hands-$NAME.log}
  remote_hands_pin_sbx_state
  remote_hands_login
  remote_hands_sbx --cloud cp "$NAME:$JOB_LOG" "$OUT"
  printf 'log: %s\n' "$OUT"
  exit 0
fi

# --- copy-in / copy-out ----------------------------------------------------
if [ "$CMD" = copy-in ] || [ "$CMD" = copy-out ]; then
  remote_hands_require_enabled
  if [ "$CMD" = copy-in ]; then
    [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { echo "error: copy-in takes <local-path> [<remote-dest>]" >&2; exit 2; }
    case "$1" in -*) echo "error: copy-in's local path may not start with '-' (got '$1'); put flags first" >&2; exit 2 ;; esac
    REMOTE_DEST=${2:-$DEFAULT_DEST_DIR/}
    remote_hands_pin_sbx_state
    remote_hands_login
    remote_hands_sbx --cloud cp "$1" "$NAME:$REMOTE_DEST"
  else
    [ "$#" -eq 2 ] || { echo "error: copy-out takes <remote-path> <local-dest>" >&2; exit 2; }
    case "$1" in -*) echo "error: copy-out's remote path may not start with '-' (got '$1'); put flags first" >&2; exit 2 ;; esac
    remote_hands_pin_sbx_state
    remote_hands_login
    remote_hands_sbx --cloud cp "$NAME:$1" "$2"
  fi
  exit 0
fi

# --- teardown --------------------------------------------------------------
if [ "$CMD" = teardown ]; then
  remote_hands_pin_sbx_state
  remote_hands_login
  remote_hands_sbx --cloud rm --force "$NAME"
  if [ -e "$(remote_hands_manifest_path "$NAME")" ]; then
    rm -f -- "$(remote_hands_manifest_path "$NAME")"
  else
    echo "note: no manifest existed for '$NAME'" >&2
  fi
  printf 'removed: name=%s\n' "$NAME"
  exit 0
fi
