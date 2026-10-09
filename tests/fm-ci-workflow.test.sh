#!/usr/bin/env bash
# Contract tests for .github/workflows/ci.yml's runner-spend safeguards.
#
# Origin: the 2026-09-12 GitHub Actions starvation incident. firstmate CI had no
# concurrency deduplication, so every superseded PR head kept its full job
# fan-out, and four jobs carried no timeout at all. These tests hold both
# safeguards: PR runs supersede within one PR while main pushes are never
# cancelled, and every CI job carries a finite hang tripwire drawn from the
# three-tier timeout policy that docs/fm-test-portable-shards.md "Timeouts"
# owns (fast, normal, heavy) plus that policy's one recorded measured exception
# (portable serial shard 2 at 45 minutes), so no job drifts back to a one-off
# number.
#
# The workflow is parsed as YAML and its concurrency expressions are resolved
# against simulated pull_request and push contexts, so the assertions describe
# what GitHub would do, not how the file happens to be spelled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"

assert_present "$CI_WORKFLOW" ".github/workflows/ci.yml is missing"
command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/ci.yml as YAML"

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>". Only the two expression constructs
# this workflow uses are resolved: an `a || b` fallback and an `==` comparison.
resolve_concurrency() {
  local event=$1 pr_number=$2 run_id=$3
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
concurrency = doc.fetch("concurrency")
context = {
  "github.workflow" => doc.fetch("name"),
  "github.event_name" => ARGV[1],
  "github.event.pull_request.number" => ARGV[2],
  "github.run_id" => ARGV[3],
}

value = lambda do |token|
  token = token.strip
  next token[1..-2] if token.start_with?("\x27") && token.end_with?("\x27")
  raise "unresolvable context reference: #{token}" unless context.key?(token)
  context.fetch(token)
end

evaluate = lambda do |expression|
  expression = expression.strip
  if expression.include?("==")
    left, right = expression.split("==", 2)
    next value.call(left) == value.call(right) ? "true" : "false"
  end
  resolved = expression.split("||").map { |token| value.call(token) }.find { |v| !v.empty? }
  resolved.to_s
end

interpolate = lambda do |raw|
  raw.to_s.gsub(/\$\{\{(.+?)\}\}/) { evaluate.call(Regexp.last_match(1)) }
end

puts [interpolate.call(concurrency.fetch("group")),
      interpolate.call(concurrency.fetch("cancel-in-progress"))].join("\t")
' "$CI_WORKFLOW" "$event" "$pr_number" "$run_id"
}

# Print one "<leg><TAB>minutes" line per effective timeout leg of a job: a
# matrix job gets one line per shard, a plain job gets one. A literal integer
# timeout prints as itself; the only expression form this workflow uses - one
# recorded per-shard exception over the tier default - is resolved against
# each leg's matrix context the way GitHub would, so the assertions describe
# effective budgets rather than how the file happens to be spelled.
job_timeouts() {  # <job>
  ruby -ryaml - "$CI_WORKFLOW" "$1" <<'RUBY'
doc = YAML.load_file(ARGV[0])
name = ARGV[1]
job = doc.fetch("jobs").fetch(name)
timeout = job.fetch("timeout-minutes") { raise "no timeout-minutes on #{name}" }
legs = [[nil, nil]]
matrix = job.dig("strategy", "matrix")
if matrix
  raise "unexpected #{name} matrix dimensions" unless matrix.keys.size == 1
  key = matrix.keys.fetch(0)
  legs = matrix.fetch(key).map { |value| [key, value] }
end
legs.each do |key, value|
  if timeout.is_a?(Integer)
    puts [(key.nil? ? "-" : "#{key}-#{value}"), timeout].join("\t")
    next
  end
  body = timeout.to_s[/\A\$\{\{(.+)\}\}\z/, 1].to_s.strip
  exception = body.match(/\Amatrix\.(\w+) == (\d+) && (\d+) \|\| (\d+)\z/)
  raise "unresolvable timeout-minutes on #{name}: #{timeout}" unless exception
  raise "timeout expression on #{name} does not read its matrix dimension" unless exception[1] == key
  minutes = value.to_i == exception[2].to_i ? exception[3].to_i : exception[4].to_i
  puts ["#{key}-#{value}", minutes].join("\t")
end
RUBY
}

# Tier membership is the executable inventory of the timeout policy: a new job
# must join a tier, and a job-level value outside these tiers is exactly the
# one-off number the policy removed. The portable serial lane is normal-tier
# too, but its legs are asserted separately because one shard carries the
# policy's single recorded measured exception.
FAST_TIER_JOBS='test-coverage invariants tests-timing-aggregate'
NORMAL_TIER_JOBS='lint tests-portable-parallel-1 tests-portable-parallel-2 macos-stock-bash'
SERIAL_LANE_JOB='tests-portable-serial'
HEAVY_TIER_JOBS='tests-herdr'

# The one measured budget exception, recorded in docs/fm-test-portable-shards.md
# "Timeouts": the cancelled "Behavior portable serial 2" check on
# https://github.com/kirkins/firstmate/pull/3 exhausted
# the shared 30-minute normal budget with every suite and gate still enabled,
# so that shard alone carries 45 minutes while the other serial shards stay at 30.
SERIAL_EXCEPTION_SHARD=2
SERIAL_EXCEPTION_TIMEOUT=45

# Print the one timeout every listed job shares; fail on any disagreement.
# These jobs are single-budget lanes: the serial lane's recorded exception leg
# is pinned by its own test below rather than averaged into a tier value.
tier_timeout() {  # <tier> <job>...
  local tier=$1 job first actual
  shift
  first=
  for job in "$@"; do
    while IFS=$'\t' read -r _ actual; do
      case "$actual" in ''|*[!0-9]*) fail "$job ($tier tier) has no integer timeout, got $actual" ;; esac
      if [ -z "$first" ]; then
        first=$actual
      elif [ "$actual" != "$first" ]; then
        fail "$tier tier jobs must share one timeout, got $first and $actual ($job)"
      fi
    done < <(job_timeouts "$job")
  done
  printf '%s\n' "$first"
}

# Print every job id in the workflow, one per line.
workflow_jobs() {
  ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("jobs").keys' "$CI_WORKFLOW"
}

group_of() { printf '%s\n' "$1" | cut -f1; }
cancel_of() { printf '%s\n' "$1" | cut -f2; }

test_pr_pushes_supersede_within_one_pr() {
  local first second
  first=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  second=$(resolve_concurrency pull_request 108 900002) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "two runs of one PR must share a concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "PR runs must cancel the in-progress run, got $(cancel_of "$first")"
  pass "a newer push to one PR supersedes that PR's in-flight CI"
}

test_separate_prs_do_not_cancel_each_other() {
  local one two
  one=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  two=$(resolve_concurrency pull_request 109 900003) || fail "could not resolve PR concurrency"
  [ "$(group_of "$one")" != "$(group_of "$two")" ] \
    || fail "distinct PRs must not share a concurrency group ($(group_of "$one"))"
  pass "distinct PRs get distinct concurrency groups"
}

test_main_pushes_are_never_cancelled() {
  local first second
  first=$(resolve_concurrency push '' 900010) || fail "could not resolve push concurrency"
  second=$(resolve_concurrency push '' 900011) || fail "could not resolve push concurrency"
  [ "$(group_of "$first")" != "$(group_of "$second")" ] \
    || fail "each main push must get its own concurrency group, got $(group_of "$first") twice"
  [ "$(cancel_of "$first")" = false ] \
    || fail "push runs must never cancel an in-progress run, got $(cancel_of "$first")"
  pass "every main push keeps its own group and is never cancelled"
}

test_every_job_has_a_finite_timeout() {
  local job legs _ minutes reported
  reported=
  while IFS= read -r job; do
    legs=$(job_timeouts "$job") || fail "could not resolve the $job timeout legs"
    [ -n "$legs" ] || fail "$job carries no timeout leg"
    while IFS=$'\t' read -r _ minutes; do
      case "$minutes" in
        ''|*[!0-9]*) reported="${reported:+$reported$'\n'}$job: $minutes" ;;
        *) [ "$minutes" -gt 0 ] || reported="${reported:+$reported$'\n'}$job: $minutes" ;;
      esac
    done <<<"$legs"
  done < <(workflow_jobs)
  [ -z "$reported" ] || fail "these CI job legs have no finite hang tripwire:"$'\n'"$reported"
  pass "every ci.yml job leg carries a finite timeout"
}

# Every job sits in exactly one tier, and the workflow carries no timeout value
# beyond the three tier budgets plus the one recorded serial exception: still
# no one-off numbers.
test_every_job_belongs_to_exactly_one_timeout_tier() {
  local expected actual distinct
  # shellcheck disable=SC2086
  expected=$(printf '%s\n' $FAST_TIER_JOBS $NORMAL_TIER_JOBS $SERIAL_LANE_JOB $HEAVY_TIER_JOBS | LC_ALL=C sort)
  [ "$(printf '%s\n' "$expected" | LC_ALL=C sort -u)" = "$expected" ] \
    || fail "a job is listed in more than one timeout tier:"$'\n'"$expected"
  actual=$(workflow_jobs | LC_ALL=C sort) || fail "could not list ci.yml jobs"
  [ "$actual" = "$expected" ] \
    || fail "ci.yml jobs and the timeout tiers disagree; every job must join one tier"$'\n'"workflow: $(printf '%s' "$actual" | tr '\n' ' ')"$'\n'"tiers: $(printf '%s' "$expected" | tr '\n' ' ')"
  distinct=$(for job in $expected; do job_timeouts "$job" | cut -f2; done | LC_ALL=C sort -u)
  [ "$(printf '%s\n' "$distinct" | wc -l | tr -d ' ')" = 4 ] \
    || fail "ci.yml must carry exactly the three tier budgets plus the one recorded serial exception, got:"$'\n'"$distinct"
  pass "every ci.yml job belongs to one of the three timeout tiers"
}

# Fast tier: seconds-long checks share one short tripwire in the 5-10 minute band.
test_fast_tier_shares_one_short_tripwire() {
  local fast
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  [ "$fast" -ge 5 ] && [ "$fast" -le 10 ] \
    || fail "fast tier must be a 5-10 minute hang tripwire, got $fast"
  pass "fast tier jobs share one $fast minute tripwire"
}

# Normal tier: every plain test or lint lane shares ONE fixed 30-minute budget,
# above the fast tier. That budget is a hang tripwire, not a packing estimate.
# Every serial shard leg joins this same budget except the recorded exception.
test_normal_tier_shares_one_budget() {
  local fast normal
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  [ "$normal" -gt "$fast" ] \
    || fail "normal tier ($normal) must exceed the fast tier ($fast)"
  [ "$normal" = 30 ] \
    || fail "normal tier must be the single 30-minute shared budget, got $normal"
  pass "normal tier jobs share one $normal minute budget"
}

# The recorded budget exception, and only it: serial shard
# $SERIAL_EXCEPTION_SHARD alone carries $SERIAL_EXCEPTION_TIMEOUT minutes,
# while every other serial leg stays on the shared normal budget, so a second
# shard exception cannot creep in as a one-off number.
test_serial_exception_is_one_recorded_shard() {
  local budget legs bad
  # shellcheck disable=SC2086
  budget=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  legs=$(job_timeouts "$SERIAL_LANE_JOB") || fail "could not read the serial lane timeout legs"
  bad=$(printf '%s\n' "$legs" | awk -F'\t' \
    -v shard="shard-$SERIAL_EXCEPTION_SHARD" \
    -v want="$SERIAL_EXCEPTION_TIMEOUT" \
    -v budget="$budget" '
      $1 == shard {
        if ($2 == want) { seen = 1 } else { print $1 " carries " $2 " minutes" }
        next
      }
      $2 == budget { next }
      { print $1 " carries " $2 " minutes" }
      END { if (!seen) print shard " does not carry its " want " minute exception" }
    ')
  [ -z "$bad" ] || fail "the serial lane must be $budget minutes except shard $SERIAL_EXCEPTION_SHARD at $SERIAL_EXCEPTION_TIMEOUT:"$'\n'"$bad"
  pass "serial shard $SERIAL_EXCEPTION_SHARD alone carries the $SERIAL_EXCEPTION_TIMEOUT minute exception"
}

# Heavy tier: Herdr alone carries a job-level last-resort backstop above the
# normal tier, while its family-run step owns a tighter tripwire so the
# always() cleanup and timing upload still run after a hang.
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop() {
  local normal heavy step
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  heavy=$(tier_timeout heavy $HEAVY_TIER_JOBS) || exit 1
  [ "$heavy" -gt "$normal" ] \
    || fail "heavy tier backstop ($heavy) must exceed the normal tier ($normal)"
  [ "$heavy" -ge 60 ] && [ "$heavy" -le 75 ] \
    || fail "heavy tier backstop must stay a 60-75 minute last resort, got $heavy"
  step=$(ruby -ryaml -e '
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("steps")
index = steps.index { |s| s["id"] == "run-real-herdr-family" }
raise "no run-real-herdr-family step" unless index
teardown = steps.index { |s| s["id"] == "cleanup-herdr-lab-sessions" }
raise "no cleanup-herdr-lab-sessions step" unless teardown
raise "teardown must follow the family-run step" unless teardown > index
raise "teardown must run under always()" unless steps[teardown]["if"].to_s.strip == "always()"
puts steps[index].fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" tests-herdr) || fail "could not read the Herdr family-run step"
  case "$step" in ''|*[!0-9]*) fail "the Herdr family-run step needs its own timeout-minutes, got $step" ;; esac
  [ "$step" = 20 ] \
    || fail "the Herdr family-run step must be the 20-minute tripwire, got $step"
  [ "$step" -lt "$heavy" ] \
    || fail "the Herdr step tripwire ($step) must stay below the job backstop ($heavy)"
  pass "Herdr keeps a $step minute step tripwire under a $heavy minute job backstop"
}

test_ci_matrices_match_executable_partitions() {
  ruby -ryaml -ropen3 - "$CI_WORKFLOW" "$ROOT" <<'RUBY' || fail "CI partition contract"
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
root = ARGV[1]
serial = jobs.fetch("tests-portable-serial").fetch("strategy")
raise "serial failures must not cancel other shards" unless serial.fetch("fail-fast") == false
matrix = serial.fetch("matrix")
raise "unexpected serial dimensions" unless matrix.keys == ["shard"]
shards = matrix.fetch("shard")
lanes, status = Open3.capture2(File.join(root, "bin/fm-test-run.sh"), "--list-lanes")
raise "cannot list runner lanes" unless status.success?
actual = lanes.lines.map(&:strip).select { |l| l.match?(/\Aportable-serial-\d+of\d+\z/) }
expected = shards.map { |s| "portable-serial-#{s}of#{shards.length}" }
raise "CI matrix and runner disagree" unless actual.sort == expected.sort
lint = jobs.fetch("lint").fetch("strategy")
raise "lint failures must not cancel another partition" unless lint.fetch("fail-fast") == false
matrix = lint.fetch("matrix")
raise "unexpected lint dimensions" unless matrix.keys == ["partition"]
parts = matrix.fetch("partition")
roots = parts.flat_map do |p|
  output, result = Open3.capture2(File.join(root, "bin/fm-lint.sh"), "--partition", "#{p}of#{parts.length}", "--list-files")
  raise "unsupported lint partition" unless result.success?
  output.lines.map(&:strip)
end
canonical, result = Open3.capture2({"CI" => "true"}, File.join(root, "bin/fm-lint.sh"), "--list-files")
raise "lint matrix loses or duplicates canonical roots" unless result.success? && roots.sort == canonical.lines.map(&:strip).sort
RUBY
  pass "CI matrices cover every executable serial lane and canonical lint root exactly once"
}

test_ci_matrices_match_executable_partitions
test_pr_pushes_supersede_within_one_pr
test_separate_prs_do_not_cancel_each_other
test_main_pushes_are_never_cancelled
test_every_job_has_a_finite_timeout
test_every_job_belongs_to_exactly_one_timeout_tier
test_fast_tier_shares_one_short_tripwire
test_normal_tier_shares_one_budget
test_serial_exception_is_one_recorded_shard
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop
