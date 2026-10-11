#!/usr/bin/env bash
# fm-forge-mail.sh - Forgejo-backed inbound mailbox for external senders.
#
# Reads one private "mailbox" repository on a Forgejo instance and surfaces
# each new open mail-labeled issue as a durable `check` wake, so an external
# sender (ChatGPT web through the forge's OAuth MCP connector, Hermes with a
# repo-scoped token, any MCP or REST client) can leave firstmate a message
# that survives a powered-off laptop on the forge's own storage. One open
# mail-labeled issue is one message: the number is the stable id, the title is
# the subject, the body is the payload, and the sender is the forge principal
# that created the issue; closed issues are the searchable history.
#
# This is an ordinary message-reading surface, not an escalation of authority:
# every surfaced message is input firstmate reads before deciding. Sender
# identity is the authenticated forge principal (issue user.login), never a
# body claim; message bodies never carry secrets; the mailbox repository must
# never contain workflows or any other automation trigger. The full security
# rules and the wake-handling contract live in docs/configuration.md "Forge
# mail plane".
#
# Subcommands:
#   poll                 Surface open mail issues this home has not yet woken
#                        as a `check` wake so firstmate handles them. The poll
#                        never writes to the forge (BODY.PEEK discipline): no
#                        issue is closed, commented, or labeled before an
#                        explicit ack, so state=open plus label=mail is always
#                        exactly the live queue. Each new issue's JSON is
#                        stashed to state/forge-mail-inbox/<n>.json at poll
#                        time so handling works offline. Emission copies the
#                        mail plane's exactly-once-recovering contract
#                        (bin/fm-mail.sh owns it): the wake row, journal, and
#                        cursor commit under one held wake-queue lock, the
#                        journal proves every published wake, and an
#                        interrupted poll is healed from the journal or the
#                        queued key, so a message is never silently missed. The
#                        repo id is the generation key: a deletion and
#                        recreation that resets issue numbering clears the
#                        cursor and journal so a reused number wakes again, and
#                        overlapping polls serialize on the forge-mail-seen
#                        lock. poll has no scheduler: run it manually or via
#                        the standing check armed by bin/fm-forge-mail-check.sh.
#   read [<n>]           Print one message by number (from the authenticated
#                        principal's login, then subject and body), fetching it
#                        live and falling back to the poll-time stash when the
#                        forge is unreachable. Without a number, print a digest
#                        of the open mail issues. A read that fails with no
#                        stash leaves the wake row unacknowledged, so it is
#                        retried visibly and never silently dropped.
#   ack <n> [--note <t>] The explicit act in firstmate's handling turn:
#                        optionally post the note as a one-line receipt
#                        comment, then close the issue. Close-on-ack keeps the
#                        open set equal to the live queue and the closed issues
#                        searchable; receipts carry no secrets, like bodies.
#   status               Print configuration and the last poll cursor. No
#                        network, no wake.
#
# Volume: poll surfaces at most FM_FORGE_MAIL_POLL_MAX_WAKES messages per run
# (default 10, valid 1..200) out of the 50 newest open mail issues; a larger
# flood surfaces on the next poll, keeping the durable wake queue bounded no
# matter how much inbound mail arrives.
#
# Deployment - endpoints are read from the environment, filling missing keys
# from the gitignored $FM_HOME/.env (same convention as the Relay/FMX token
# and the mail plane; env wins). Add these two required values plus the
# optional tuning:
#   FM_FORGE_MAIL_HOST=<forge host, e.g. git.example.net>
#   FM_FORGE_MAIL_REPO=<owner/name, e.g. firstmate/mailbox>
#   FM_FORGE_MAIL_POLL_MAX_WAKES=<n>   (default 10, valid 1..200)
#   FM_FORGE_MAIL_TIMEOUT=<seconds>    (default 20; HTTP timeout)
# The plane is off unless both required values are non-empty: poll is then a
# hard no-op (exit 0, no output) like bin/fm-x-poll.sh's off state, so an
# unconfigured home pays nothing. FM_HOME falls back to the repo root when
# unset. This script carries no secret and no default endpoint that could
# resolve against a wrong home; read/ack on an unconfigured home fail naming
# the missing values. The wake library is sourced from next to this script,
# not from $FM_HOME/bin; cursor, journal, and stash stay under $FM_HOME/state.
#
# The token is the dedicated least-privilege drain token firstmate stores at
# setup in the Linux keyring under service "<host>/forgejo-mail/drain"; these
# scripts never mint one. The accessor copies bin/fm-pr-merge.sh's Forgejo
# shape: one secret-tool lookup into one shell variable, bearer-shape
# validated, reaching curl only as a header read from a file descriptor, never
# an argument, a log, or a wake line.

set -euo pipefail

# --- resolve home, env, and endpoints -------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-}"
if [ -z "$FM_HOME" ]; then
  FM_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
ENV_FILE="$FM_HOME/.env"
# Load the home .env for keys not already set, so a direct invocation's
# environment overrides .env exactly like the Relay/FMX contract (fmx_env_get:
# "env wins over .env"). Tolerates a leading "export ", surrounding whitespace,
# one layer of matching quotes, comments, and blank lines.
if [ -f "$ENV_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      ''|\#*) continue ;;
      export\ *) line="${line#export }" ;;
    esac
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    key="${key#"${key%%[![:space:]]*}"}"
    val="${line#*=}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    case "$val" in
      \"*\") val=${val#\"}; val=${val%\"} ;;
      \'*\') val=${val#\'}; val=${val%\'} ;;
    esac
    if [ -n "$key" ] && [ -z "${!key:-}" ]; then
      export "$key=$val"
    fi
  done < "$ENV_FILE"
fi

FORGE_HOST="$(printf '%s' "${FM_FORGE_MAIL_HOST:-}" | tr '[:upper:]' '[:lower:]')"
MAILBOX_REPO="${FM_FORGE_MAIL_REPO:-}"
MAX_WAKES="${FM_FORGE_MAIL_POLL_MAX_WAKES:-10}"
case "$MAX_WAKES" in
  ''|*[!0-9]*|0) MAX_WAKES=10 ;;
esac
if [ "$MAX_WAKES" -gt 200 ]; then
  MAX_WAKES=200
fi
TIMEOUT_SECS="${FM_FORGE_MAIL_TIMEOUT:-20}"
case "$TIMEOUT_SECS" in
  ''|*[!0-9]*|0) TIMEOUT_SECS=20 ;;
esac
# The poll reads at most the newest LIST_LIMIT open mail issues per run; the
# wake cap below, not this window, bounds the queue, and older issues surface
# on later polls once newer ones are acknowledged or capped through.
LIST_LIMIT=50

STATE_DIR="$FM_HOME/state"
mkdir -p "$STATE_DIR"
CURSOR="$STATE_DIR/.forge-mail-seen"
# Durable emission journal: every successfully published poll wake records its
# issue number here under the queue lock, immediately after the wake row is
# appended and before the cursor records it. bin/fm-mail.sh owns this
# contract's semantics; this is the same journal over issue numbers.
WOKEN="$STATE_DIR/.forge-mail-woken"
# Poll-time stash of each surfaced issue's JSON, so firstmate can read a
# message while offline (the x-inbox pattern). Removed by ack and cleared on a
# generation change.
STASH_DIR="$STATE_DIR/forge-mail-inbox"

usage() {
  cat <<'EOF'
fm-forge-mail.sh poll
fm-forge-mail.sh read [<n>]
fm-forge-mail.sh ack <n> [--note <text>]
fm-forge-mail.sh status
EOF
}

forge_mail_configured() {
  [ -n "$FORGE_HOST" ] && [ -n "$MAILBOX_REPO" ]
}

forge_mail_require_config() {
  if ! forge_mail_configured; then
    echo "fm-forge-mail: this command requires FM_FORGE_MAIL_HOST and FM_FORGE_MAIL_REPO (set them in $ENV_FILE)" >&2
    return 1
  fi
  return 0
}

# Host shape guard for the URL the API client builds from it: no scheme, path,
# or whitespace can smuggle into https://<host>/api/v1. A lowercase spelling
# was already resolved above, so the charset is the DNS-safe remainder.
forge_mail_host_valid() {  # $1 = host
  local host=${1-} label
  local -a labels
  [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || return 1
  case "$host" in
    .*|*.|*..*|*[!a-z0-9.-]*) return 1 ;;
  esac
  IFS=. read -ra labels <<< "$host"
  for label in "${labels[@]}"; do
    [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
    case "$label" in
      -*|*-) return 1 ;;
    esac
  done
}

# Mailbox repository shape guard: exactly owner/name, each segment the forge's
# own conservative character set, so the API path cannot walk or split.
forge_mail_repo_valid() {  # $1 = owner/name
  local repo=${1-} owner name
  [ "${#repo}" -ge 3 ] && [ "${#repo}" -le 201 ] || return 1
  case "$repo" in
    /*|*/|*//*) return 1 ;;
  esac
  owner=${repo%%/*}
  name=${repo#*/}
  [ "$owner" != "$repo" ] || return 1
  [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 100 ] || return 1
  case "$owner" in
    .|..|*[!A-Za-z0-9_-]*) return 1 ;;
  esac
  [ "${#name}" -ge 1 ] && [ "${#name}" -le 100 ] || return 1
  case "$name" in
    .|..|*.git|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# The dedicated least-privilege drain token for one forge host, read from the
# Linux keyring slot named for this plane: service "<host>/forgejo-mail/drain".
# The lookup itself is the only credential access, so the token lands in one
# shell variable and never on a command line; a slot that is missing, empty, or
# not a bearer token shape fails here rather than sending a malformed
# credential. Firstmate stores the token at setup; this script never mints one.
forge_mail_token() {  # $1 = host
  local token
  local LC_ALL=C
  command -v secret-tool >/dev/null 2>&1 || return 1
  forge_mail_host_valid "$1" || return 1
  token=$(secret-tool lookup service "$1/forgejo-mail/drain" 2>/dev/null) || return 1
  [[ "$token" =~ ^[A-Za-z0-9_-]{20,256}$ ]] || return 1
  printf '%s' "$token"
}

# One Forgejo REST call. <method> <api-path> <out-file> [<json-body>] writes
# the response body to <out-file>, prints the HTTP status code, and returns
# non-zero when curl itself failed. The caller judges the code. The
# authorization header reaches curl as a header read from a file descriptor
# (bin/fm-pr-merge.sh's established shape), so the token never appears in a
# process argument list; the host and repository were validated above, and a
# ".." segment is still refused so no path can walk out of /api/v1.
forge_mail_api() {  # <method> <api-path> <out-file> [<json-body>]
  local method=$1 api_path=$2 out=$3 body=${4-} token code
  local LC_ALL=C
  local -a args
  command -v curl >/dev/null 2>&1 || return 1
  forge_mail_host_valid "$FORGE_HOST" || return 1
  case "$api_path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$api_path" in
    */../*|*/..) return 1 ;;
  esac
  [ -f "$out" ] || return 1
  token=$(forge_mail_token "$FORGE_HOST") || return 1
  args=(-sS --max-time "$TIMEOUT_SECS" -o "$out" -w '%{http_code}' -X "$method"
    -H @/dev/fd/3 "https://$FORGE_HOST/api/v1$api_path")
  if [ -n "$body" ]; then
    args=(-H 'Content-Type: application/json' --data "$body" "${args[@]}")
  fi
  code=$(curl "${args[@]}" 3< <(printf 'Authorization: token %s\n' "$token") 2>/dev/null) || return 1
  printf '%s\n' "$code"
}

# Named prerequisites for every forge-touching command, reported together and
# before anything is recorded, so a missing tool or token is a named setup gap
# rather than a poll that fails for an unexplained reason.
forge_mail_check_tools() {
  local missing=
  command -v curl >/dev/null 2>&1 || missing="curl"
  command -v jq >/dev/null 2>&1 || missing="${missing:+$missing and }jq"
  command -v secret-tool >/dev/null 2>&1 || missing="${missing:+$missing and }secret-tool"
  if [ -n "$missing" ]; then
    echo "fm-forge-mail: this command requires $missing on PATH" >&2
    return 1
  fi
  if ! forge_mail_token "$FORGE_HOST" >/dev/null; then
    echo "fm-forge-mail: $FORGE_HOST requires the dedicated drain token in the Linux keyring under service $FORGE_HOST/forgejo-mail/drain" >&2
    return 1
  fi
}

forge_mail_seen() {
  # $1 = issue number; returns 0 when the cursor already records it as surfaced.
  grep -Fqx "$1" "$CURSOR"
}

forge_mail_stored_generation() {
  # Print the repo generation the local cursor was last reset to, or "".
  [ -f "$CURSOR" ] || : > "$CURSOR"
  grep -m1 '^generation=' "$CURSOR" | cut -d= -f2 || true
}

# Write the journal and cursor records; return 0 only when the journal (the
# proof a wake was published) committed. The journal is written FIRST and is
# mandatory: an issue can never be cursor-recorded without the journal
# recording its wake, so a crash or write failure can never leave a number
# cursor-recorded but silently suppressed. bin/fm-mail.sh owns this
# transaction's rationale; this is the same two records over issue numbers.
forge_mail_record_evidence() {
  local generation=$1 id=$2
  if ! printf '%s\t%s\n' "$generation" "$id" >> "$WOKEN"; then
    return 1
  fi
  if ! printf '%s\n' "$id" >> "$CURSOR"; then
    # Journal committed but the cursor did not: the wake is still proven by
    # the journal and healed into the cursor on the next poll. Returning 0
    # keeps the durable contract: a journal entry always means the wake was
    # published.
    return 0
  fi
  return 0
}

# Remove a just-appended wake row plus any partial journal/cursor evidence.
# Runs under the held FM_WAKE_QUEUE_LOCK, so the rewrite cannot race an
# acknowledgement. The journal entry is removed FIRST and required: deleting
# the wake row while a journal entry survives would let the next heal mark the
# issue surfaced without a wake. If the journal cannot be verified and cleaned,
# fail the rollback so the row stays queued and is delivered - never
# suppressed.
forge_mail_rollback_wake_locked() {
  local wake_key=$1 generation=$2 id=$3 clean_key tmp jtmp
  clean_key=$(printf '%s' "$wake_key" | fm_wake_clean_field)
  if awk -F '\t' -v g="$generation" -v i="$id" \
      '$1 == g && $2 == i { found=1 } END { exit found ? 0 : 1 }' \
      "$WOKEN" 2>/dev/null; then
    jtmp=$(mktemp "$WOKEN.rm.XXXXXX") || return 1
    if ! awk -F '\t' -v g="$generation" -v i="$id" \
        '!($1 == g && $2 == i)' "$WOKEN" > "$jtmp" 2>/dev/null; then
      rm -f -- "$jtmp"
      return 1
    fi
    if ! mv -f -- "$jtmp" "$WOKEN" 2>/dev/null; then
      rm -f -- "$jtmp"
      return 1
    fi
  fi
  tmp=$(mktemp "$FM_WAKE_QUEUE.rollback.XXXXXX") || return 1
  if ! awk -F '\t' -v key="$clean_key" '
    NF >= 5 && $3 == "check" && $4 == key { next }
    { print }
  ' "$FM_WAKE_QUEUE" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" 2>/dev/null || true
  if ! mv -f -- "$tmp" "$FM_WAKE_QUEUE"; then
    rm -f -- "$tmp"
    return 1
  fi
  if grep -vx -e "$id" "$CURSOR" > "$CURSOR.tmp.$$" 2>/dev/null; then
    if mv -f -- "$CURSOR.tmp.$$" "$CURSOR" 2>/dev/null; then
      :
    fi
  fi
  rm -f -- "$CURSOR.tmp.$$"
  return 0
}

# Publish one `check` wake and its durable records under a single held
# FM_WAKE_QUEUE_LOCK. bin/fm-mail.sh's wake_for owns this transaction's
# contract; this is the same transaction keyed by generation/issue-number, so
# a recreated repo's reused number can never collide with a stale wake key.
# Returns:
#   0 - the wake row was appended and a durable record landed.
#   1 - the wake row was appended and rolled back; nothing was delivered.
#   2 - the wake row survived with no durable record (fail-closed); the drain
#       delivers it and the next poll's heal records the number.
#   3 - the wake row was never appended; nothing was delivered.
forge_mail_wake_for() {
  local generation=$1 id=$2 summary=$3 lib="$SCRIPT_DIR/fm-wake-lib.sh" status=0
  local wake_key="forge-mail:$generation/$id"
  if [ ! -f "$lib" ]; then
    echo "fm-forge-mail: $lib missing; cannot wake" >&2
    return 1
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$lib"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  if fm_wake_append_locked check "$wake_key" "check: forge-mail $MAILBOX_REPO#$id - $summary"; then
    if forge_mail_record_evidence "$generation" "$id"; then
      :
    elif forge_mail_rollback_wake_locked "$wake_key" "$generation" "$id"; then
      echo "fm-forge-mail: wake for $MAILBOX_REPO#$id rolled back (journal and cursor writes failed); retried on next poll" >&2
      status=1
    elif forge_mail_record_evidence "$generation" "$id"; then
      echo "fm-forge-mail: wake for $MAILBOX_REPO#$id durably recorded after the queue rewrite failed" >&2
    else
      echo "fm-forge-mail: wake for $MAILBOX_REPO#$id could not be rolled back or durably recorded; the wake stays queued and the next poll heals it - a possible duplicate, never a lost message" >&2
      status=2
    fi
  else
    echo "fm-forge-mail: wake append failed for $MAILBOX_REPO#$id; retried on next poll" >&2
    status=3
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

# Reconcile a poll interrupted between its operations, from the same durable
# evidence the mail plane's heal uses (bin/fm-mail.sh owns the contract): a
# journal entry proves a published wake even after the drain acknowledged and
# removed its row, and a queued wake key proves one appended before any record
# landed. Both are generation-scoped, so a stale prior-generation record can
# never mark a reused number as surfaced in the recreated repo.
forge_mail_heal() {
  local generation=$1 jgen jid keyrest keygen keyid heal_ok=0
  if [ -s "$WOKEN" ]; then
    while IFS=$'\t' read -r jgen jid; do
      [ -n "$jid" ] || continue
      [ "$jgen" != "$generation" ] && continue
      if ! forge_mail_seen "$jid"; then
        if printf '%s\n' "$jid" >> "$CURSOR"; then
          :
        else
          heal_ok=1
        fi
      fi
    done < "$WOKEN"
    # Drop the journal once every number is durably recorded; if any cursor
    # write failed, keep the whole journal so the next poll can retry it.
    if [ "$heal_ok" -eq 0 ]; then
      : > "$WOKEN"
    fi
  fi
  while IFS= read -r k; do
    keyrest="${k#forge-mail:}"
    [ "$keyrest" = "$k" ] && continue
    keygen=""
    keyid=""
    case "$keyrest" in
      */*) keygen="${keyrest%%/*}"; keyid="${keyrest#*/}" ;;
      *) keyid="$keyrest" ;;
    esac
    [ -z "$keyid" ] && continue
    [ "$keygen" != "$generation" ] && continue
    if ! forge_mail_seen "$keyid"; then
      if printf '%s\n' "$keyid" >> "$CURSOR"; then
        :
      else
        heal_ok=1
      fi
    fi
  done < <(fm_wake_queued_keys check 2>/dev/null || true)
  return "$heal_ok"
}

# Stash one surfaced issue's JSON from the poll's list payload for offline
# reading, atomically and privately: the bytes arrive by rename so a reader
# never sees a half-written stash.
forge_mail_stash_issue() {
  local payload=$1 n=$2 tmp
  mkdir -p "$STASH_DIR" || return 1
  chmod 0700 "$STASH_DIR" 2>/dev/null || true
  tmp=$(mktemp "$STASH_DIR/.stash.XXXXXX") || return 1
  if ! jq --argjson n "$n" '.[] | select(.number == $n)' "$payload" > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$STASH_DIR/$n.json"
}

forge_mail_poll_inner() {
  # $1 = scratch payload file, reused for both GETs. All work runs under the
  # caller's seen lock.
  local out=$1 code generation list line n login title subject stashed woke=0
  if ! code=$(forge_mail_api GET "/repos/$MAILBOX_REPO" "$out"); then
    echo "fm-forge-mail: could not reach https://$FORGE_HOST/api/v1/repos/$MAILBOX_REPO" >&2
    return 1
  fi
  if [ "$code" != 200 ]; then
    echo "fm-forge-mail: reading mailbox repo $MAILBOX_REPO failed with HTTP $code" >&2
    return 1
  fi
  generation=$(jq -r 'if (.id | type) == "number" then (.id | tostring) else "" end' "$out" 2>/dev/null) || generation=
  if [ -z "$generation" ]; then
    echo "fm-forge-mail: mailbox repo payload is unreadable" >&2
    return 1
  fi
  # A repo deletion and recreation resets issue numbering; a stale cursor must
  # not suppress the reused numbers. Journal entries and stashes from the old
  # repo are equally stale, so both are cleared rather than risk healing a
  # reused number into the new generation.
  if [ "$(forge_mail_stored_generation)" != "$generation" ]; then
    printf 'generation=%s\n' "$generation" > "$CURSOR"
    : > "$WOKEN"
    if [ -d "$STASH_DIR" ]; then
      for stashed in "$STASH_DIR"/[0-9]*.json; do
        [ -f "$stashed" ] && rm -f -- "$stashed"
      done
    fi
  fi
  if ! forge_mail_heal "$generation"; then
    echo "fm-forge-mail: heal could not record an issue; journal kept; retried on next poll" >&2
    return 1
  fi
  if ! code=$(forge_mail_api GET "/repos/$MAILBOX_REPO/issues?labels=mail&type=issues&state=open&limit=$LIST_LIMIT&page=1" "$out"); then
    echo "fm-forge-mail: could not reach the mailbox issue list on $FORGE_HOST" >&2
    return 1
  fi
  if [ "$code" != 200 ]; then
    echo "fm-forge-mail: reading the mailbox issue list failed with HTTP $code" >&2
    return 1
  fi
  if ! jq -e 'type == "array"' "$out" >/dev/null 2>&1; then
    echo "fm-forge-mail: mailbox issue list payload is unreadable" >&2
    return 1
  fi
  # Oldest first, so a capped flood surfaces in arrival order; @tsv escapes
  # tab/newline/backslash inside a field, so a title can never split a row.
  list=$(jq -r 'sort_by(.number) | .[] | [(.number | tostring), (.user.login // "unknown"), (.title // "")] | @tsv' "$out" 2>/dev/null) || list=
  # cut -f keeps empty TSV fields; IFS-tab read would collapse an empty title.
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    n=$(printf '%s\n' "$line" | cut -f1)
    login=$(printf '%s\n' "$line" | cut -f2)
    title=$(printf '%s\n' "$line" | cut -f3)
    [ -z "$n" ] && continue
    case "$n" in
      *[!0-9]*) continue ;;
    esac
    if ! forge_mail_seen "$n"; then
      # Reaching the per-poll wake cap stops the loop: the remaining open
      # issues stay out of the cursor and surface on the next poll, so a
      # flood bounds the durable wake queue instead of flooding firstmate.
      if [ "$woke" -ge "$MAX_WAKES" ]; then
        echo "fm-forge-mail: per-poll wake cap ($MAX_WAKES) reached; remaining mail surfaces on the next poll" >&2
        break
      fi
      # Stash before the wake: a stash that cannot be written fails the poll
      # so the next run retries, instead of waking a message whose body could
      # not be preserved for offline handling.
      if ! forge_mail_stash_issue "$out" "$n"; then
        echo "fm-forge-mail: could not stash $MAILBOX_REPO#$n for offline reading; retried on next poll" >&2
        return 1
      fi
      subject=$(printf '%s\n' "$title" | cut -c1-100)
      if ! forge_mail_wake_for "$generation" "$n" "message from ${login:-unknown} - ${subject:-no subject}"; then
        echo "fm-forge-mail: wake failed for $MAILBOX_REPO#$n; retried on next poll" >&2
        return 1
      fi
      echo "fm-forge-mail: woke for $MAILBOX_REPO#$n"
      woke=$((woke + 1))
    fi
  done <<< "$list"
  if [ "$woke" -eq 0 ]; then
    echo "fm-forge-mail: no new mail"
  fi
  return 0
}

forge_mail_poll() {
  local tmp rc=0
  if [ ! -f "$SCRIPT_DIR/fm-wake-lib.sh" ]; then
    echo "fm-forge-mail: $SCRIPT_DIR/fm-wake-lib.sh missing; cannot poll" >&2
    return 1
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # Overlapping polls serialize on the seen lock; each poll first heals a run
  # interrupted between its phases, so an overlapping or interrupted run can
  # never lose a message.
  fm_lock_acquire_wait "$STATE_DIR/.forge-mail-seen.lock"
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-forge-mail-poll.XXXXXX") || {
    fm_lock_release "$STATE_DIR/.forge-mail-seen.lock"
    return 1
  }
  forge_mail_poll_inner "$tmp" || rc=$?
  rm -f -- "$tmp"
  fm_lock_release "$STATE_DIR/.forge-mail-seen.lock"
  return "$rc"
}

forge_mail_read() {
  local n=${1:-} out code src rc=0
  if [ -z "$n" ]; then
    out=$(mktemp "${TMPDIR:-/tmp}/fm-forge-mail-read.XXXXXX") || return 1
    if ! code=$(forge_mail_api GET "/repos/$MAILBOX_REPO/issues?labels=mail&type=issues&state=open&limit=$LIST_LIMIT&page=1" "$out"); then
      echo "fm-forge-mail: could not reach the mailbox issue list on $FORGE_HOST" >&2
      rm -f -- "$out"
      return 1
    fi
    if [ "$code" != 200 ]; then
      echo "fm-forge-mail: reading the mailbox issue list failed with HTTP $code" >&2
      rm -f -- "$out"
      return 1
    fi
    jq -r --arg repo "$MAILBOX_REPO" 'sort_by(.number) | .[] | "#" + (.number | tostring) + "  " + (.user.login // "unknown") + "  " + (.title // "")' "$out" 2>/dev/null || rc=1
    rm -f -- "$out"
    return "$rc"
  fi
  case "$n" in
    ''|*[!0-9]*)
      echo "fm-forge-mail: read needs an issue number, got: $n" >&2
      return 1
      ;;
  esac
  out=$(mktemp "${TMPDIR:-/tmp}/fm-forge-mail-read.XXXXXX") || return 1
  src=""
  if code=$(forge_mail_api GET "/repos/$MAILBOX_REPO/issues/$n" "$out") && [ "$code" = 200 ]; then
    src=$out
  elif [ -f "$STASH_DIR/$n.json" ]; then
    echo "fm-forge-mail: live fetch failed (HTTP ${code:-unreachable}); reading the poll-time stash for $MAILBOX_REPO#$n" >&2
    src="$STASH_DIR/$n.json"
  else
    echo "fm-forge-mail: cannot read $MAILBOX_REPO#$n (HTTP ${code:-unreachable}) and no poll-time stash exists" >&2
    rm -f -- "$out"
    return 1
  fi
  # `from:` is the authenticated principal's login, never a body claim: the
  # identity line a handling turn trusts is printed from user.login.
  jq -r --arg repo "$MAILBOX_REPO" '
    "issue: " + $repo + "#" + (.number | tostring),
    "from: " + (.user.login // "unknown"),
    "subject: " + (.title // ""),
    "state: " + (.state // "unknown"),
    "body:",
    (.body // "")
  ' "$src" 2>/dev/null || rc=1
  rm -f -- "$out"
  return "$rc"
}

forge_mail_ack() {
  local n=$1 note=${2:-} out code body closed stored fetched
  case "$n" in
    ''|*[!0-9]*)
      echo "fm-forge-mail: ack needs an issue number, got: $n" >&2
      return 1
      ;;
  esac
  out=$(mktemp "${TMPDIR:-/tmp}/fm-forge-mail-ack.XXXXXX") || return 1
  if ! code=$(forge_mail_api GET "/repos/$MAILBOX_REPO" "$out"); then
    echo "fm-forge-mail: could not fetch the mailbox generation on $FORGE_HOST to verify $MAILBOX_REPO#$n; refusing to ack" >&2
    rm -f -- "$out"
    return 1
  fi
  if [ "$code" != 200 ]; then
    echo "fm-forge-mail: fetching the mailbox generation for $MAILBOX_REPO#$n failed with HTTP $code; refusing to ack" >&2
    rm -f -- "$out"
    return 1
  fi
  fetched=$(jq -r 'if (.id | type) == "number" then (.id | tostring) else "" end' "$out" 2>/dev/null) || fetched=
  if [ -z "$fetched" ]; then
    echo "fm-forge-mail: the mailbox repo payload is unreadable; refusing to ack $MAILBOX_REPO#$n" >&2
    rm -f -- "$out"
    return 1
  fi
  stored=$(forge_mail_stored_generation)
  if [ -n "$stored" ] && [ "$stored" != "$fetched" ]; then
    echo "fm-forge-mail: refusing to ack $MAILBOX_REPO#$n: the mailbox repo was recreated (stored generation $stored, forge generation $fetched); run poll first" >&2
    rm -f -- "$out"
    return 1
  fi
  if [ -n "$note" ]; then
    body=$(jq -nc --arg body "$note" '{body: $body}') || { rm -f -- "$out"; return 1; }
    if ! code=$(forge_mail_api POST "/repos/$MAILBOX_REPO/issues/$n/comments" "$out" "$body"); then
      echo "fm-forge-mail: could not post the ack receipt on $MAILBOX_REPO#$n" >&2
      rm -f -- "$out"
      return 1
    fi
    case $code in 200|201) ;; *)
      echo "fm-forge-mail: posting the ack receipt on $MAILBOX_REPO#$n failed with HTTP $code" >&2
      rm -f -- "$out"
      return 1
    esac
  fi
  body=$(jq -nc '{state: "closed"}') || { rm -f -- "$out"; return 1; }
  if ! code=$(forge_mail_api PATCH "/repos/$MAILBOX_REPO/issues/$n" "$out" "$body"); then
    echo "fm-forge-mail: could not close $MAILBOX_REPO#$n" >&2
    rm -f -- "$out"
    return 1
  fi
  case $code in 200|201) ;; *)
    echo "fm-forge-mail: closing $MAILBOX_REPO#$n failed with HTTP $code" >&2
    rm -f -- "$out"
    return 1
  esac
  closed=$(jq -r '.state // ""' "$out" 2>/dev/null) || closed=
  if [ "$closed" != "closed" ]; then
    echo "fm-forge-mail: $MAILBOX_REPO#$n did not report closed (state: ${closed:-unreadable})" >&2
    rm -f -- "$out"
    return 1
  fi
  rm -f -- "$out"
  # Record the number locally so a later reopen cannot be suppressed by the
  # closed state alone, and drop its stash: the searchable history now lives
  # on the forge. Both are best-effort behind the verified close.
  if [ -f "$CURSOR" ] && ! grep -Fqx "$n" "$CURSOR"; then
    if ! printf '%s\n' "$n" >> "$CURSOR" 2>/dev/null; then
      echo "fm-forge-mail: could not record $MAILBOX_REPO#$n in the local cursor; the closed issue still leaves the poll set" >&2
    fi
  fi
  rm -f -- "$STASH_DIR/$n.json" 2>/dev/null || true
  echo "acked: $MAILBOX_REPO#$n closed"
  return 0
}

forge_mail_status() {
  local gen count
  if ! forge_mail_configured; then
    echo "forge-mail: off (set FM_FORGE_MAIL_HOST and FM_FORGE_MAIL_REPO in $ENV_FILE)"
    return 0
  fi
  echo "forge host: $FORGE_HOST"
  echo "mailbox: $MAILBOX_REPO"
  echo "label: mail"
  echo "wake cap: $MAX_WAKES"
  echo "timeout: $TIMEOUT_SECS"
  gen="-"
  count=0
  if [ -f "$CURSOR" ]; then
    gen=$(forge_mail_stored_generation)
    gen=${gen:--}
    count=$(grep -cv '^generation=' "$CURSOR" 2>/dev/null || true)
    count=${count:-0}
  fi
  echo "generation: $gen"
  echo "seen issues: $count"
  return 0
}

case "${1:-}" in
  poll)
    # Off unless configured: a hard no-op, so an unconfigured home (and the
    # standing check watching it) pays nothing and says nothing.
    forge_mail_configured || exit 0
    forge_mail_host_valid "$FORGE_HOST" || {
      echo "fm-forge-mail: FM_FORGE_MAIL_HOST is not a valid host: $FORGE_HOST" >&2
      exit 1
    }
    forge_mail_repo_valid "$MAILBOX_REPO" || {
      echo "fm-forge-mail: FM_FORGE_MAIL_REPO must be owner/name: $MAILBOX_REPO" >&2
      exit 1
    }
    forge_mail_check_tools || exit 1
    forge_mail_poll
    ;;
  read)
    forge_mail_require_config || exit 1
    forge_mail_host_valid "$FORGE_HOST" || {
      echo "fm-forge-mail: FM_FORGE_MAIL_HOST is not a valid host: $FORGE_HOST" >&2
      exit 1
    }
    forge_mail_repo_valid "$MAILBOX_REPO" || {
      echo "fm-forge-mail: FM_FORGE_MAIL_REPO must be owner/name: $MAILBOX_REPO" >&2
      exit 1
    }
    forge_mail_check_tools || exit 1
    forge_mail_read "${2:-}"
    ;;
  ack)
    forge_mail_require_config || exit 1
    forge_mail_host_valid "$FORGE_HOST" || {
      echo "fm-forge-mail: FM_FORGE_MAIL_HOST is not a valid host: $FORGE_HOST" >&2
      exit 1
    }
    forge_mail_repo_valid "$MAILBOX_REPO" || {
      echo "fm-forge-mail: FM_FORGE_MAIL_REPO must be owner/name: $MAILBOX_REPO" >&2
      exit 1
    }
    forge_mail_check_tools || exit 1
    note=""
    if [ "${3:-}" = "--note" ]; then
      note="${4:-}"
    elif [ -n "${3:-}" ]; then
      usage >&2
      echo "fm-forge-mail: unknown ack argument: $3" >&2
      exit 1
    fi
    forge_mail_ack "${2:-}" "$note"
    ;;
  status)
    forge_mail_status
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
