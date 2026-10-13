# Focused product validation

External Codex validated runtime commit `b373018765f1b3cd3fda45259b5dba3f3d91db08` in the assigned Test phase.
All product probes below used this worktree's executable implementation, private disposable fixtures, and real Pi 1.1.0 AgentSession/ExtensionRunner where applicable.
Provider transport was intercepted locally, and watcher child scripts controlled failure and readiness timing; these proofs do not claim provider/model judgment or a production fleet exercise.
The ownership probe ran the real dispatch, grant, and drain CLI commands.

| User-visible scenario | Observable result | Evidence |
|---|---|---|
| Fresh work beside older main claims | 43 main claims exclude only those rows; all 48 fresh rows remain eligible. Intervening row 44 claim refuses the overlapping grant atomically; branch acknowledges 47 rows and preserves 44 main rows. | [CLI transcript](ownership-cli-transcript.json) |
| Corrupt claims, corrupt claimed rows, and decision precedence | Empty, duplicate, malformed, and symlinked claims refuse safely; corrupt already-claimed queue rows still invalidate the full scan; old decision triggers refuse while unrelated fresh triggers remain eligible. | [CLI transcript](ownership-cli-transcript.json) |
| Publication contention | Both modes attempt publication twice. One race publishes only rows 2/3, preserving main row 1; repeated contention never prompts branch and reaches main. | [once](publication-once-events.json), [repeat](publication-repeat-events.json) |
| Routine burst with human input | One queued routine invitation covers three durable rows, successor monitoring continues, and the human follow-up reaches actual user message_start. | [events](pi-session-events.json), [native session](pi-notifications-session.html) |
| Idle construction and exact consumption | before_agent_start holds the bound with an empty public queue; exact user message_start permits the next invitation. | [events](idle-consumption-events.json), [native session](idle-consumption-session.html) |
| Manual compaction success | No phantom invitation at preparation or held completion hook; fresh close restores exactly one queued invitation with all durable rows. | [events](delivery-lifecycle-events.json), [native session](delivery-lifecycle-session.html) |
| Manual compaction failure and cancellation | Real session_compact_failed boundaries end compaction; later close restores one invitation without erasing durable work. | [failure](compaction-failure-events.json), [cancel](compaction-cancel-events.json) |
| Credential rejection and restoration | Local placeholder logout causes no queue/user-start/settlement. Placeholder login itself starts no turn; a fresh close restores one constructing invitation, later closes coalesce, exact consumption allows the next. | [events](delivery-lifecycle-events.json) |
| Notification during held asynchronous settlement | A is deferred outside the public queue; releasing settlement and holding its idle construction produces one send and exactly one actual user message_start. | [events](delivery-lifecycle-events.json), [native session](delivery-lifecycle-session.html) |
| Escape during successor readiness | No automatic restart after the abort; fresh watcher event restores delivery. | [events](aborted-ready-events.json), [native session](aborted-ready-session.html) |
| Fresh exhaustion alarm after another abort | Alarm stays deferred, retains failure details, and survives actual extension reload/replacement. | [events](aborted-exhaustion-events.json), [native session](aborted-exhaustion-session.html) |
| Fresh exhaustion alarm after original invitation consumption | The old invitation is consumed during readiness; the distinct failure alarm still reaches message_start once and failed children retire. | [events](consumed-exhaustion-events.json), [native session](consumed-exhaustion-session.html) |
| Urgent confirmation failure beside routine notification | Urgent alarm bypasses the routine bound, preserves human follow-up and durable rows, is consumed once, and normal monitoring resumes. | [events](urgent-alarm-events.json), [native session](urgent-alarm-session.html) |

The same delivery proof against pre-settlement-fix commit `10e90661` fails at `Settlement replay duplicated an in-flight invitation`; the target passes.
[Before-fix runtime failure](settlement-before-fix.log) is an expected negative control, not a failure of the target.

Evidence drivers are retained here as `reproduce-*.sh` and `reproduce-ownership.py`.
Shared probe environment:

```sh
FM_PI_PACKAGE_DIR=/private/tmp/firstmate-notification-sdk-20261013/node_modules/@earendil-works/pi-coding-agent
FM_PI_BRANCH_LIVE_E2E=1
FM_REAL_ROOT=$PWD
TMPDIR=$PWD/.validation-tmp
FM_TEST_EVIDENCE_DIR=/Users/philipkirkbride/.no-mistakes/evidence/01M4T7GDD9T0QQZBJ8T889926Y
FM_TEST_HEAD=b373018765f1b3cd3fda45259b5dba3f3d91db08
```

Ran `reproduce-ownership.py`, `reproduce-delivery-lifecycle.sh`, notification/idle/urgent drivers, compaction failure/cancel drivers, alarm driver with `FM_ALARM_MODE=aborted-ready|aborted-exhaustion|consumed-exhaustion`, and publication driver with `FM_RACE_MODE=once|repeat`.
Alarm runs also set `FM_PI_ARM_READY_TIMEOUT_MS=3000`, `FM_WATCH_REARM_RETRY_LIMIT=1`, `FM_WATCH_REARM_RETRY_BASE_MS=5`, `FM_WATCH_REARM_RETRY_MAX_MS=10`, and `FM_WATCH_EXTENSION_LOG_KEEP_LINES=150`.
All target product assertions passed.
Initial evidence-driver filename and race-variable mistakes were corrected before successful reruns.
The notification and urgent drivers were rerun after copying the public queue arrays at checkpoint time to avoid later queue mutation changing recorded checkpoints.

Reviewer-visible native Pi HTML exports were generated by the actual sessions.
Screenshot capture was attempted with Computer Use: in-app browser was unavailable, and Chrome rejected file URLs under its browser security policy.
No browser-policy workaround was attempted.

No production home, fleet pane, credential store, provider/model configuration, source, permanent test, lint/static-analysis phase, pipeline lifecycle, push, PR, CI, or merge was changed or executed.

Targeted test commands:

```sh
FM_PI_PACKAGE_DIR=/private/tmp/firstmate-notification-sdk-20261013/node_modules/@earendil-works/pi-coding-agent FM_PI_BRANCH_LIVE_E2E=1 bash bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 180 --json /Users/philipkirkbride/.no-mistakes/evidence/01M4T7GDD9T0QQZBJ8T889926Y/focused-tests.json tests/fm-pi-watch-extension.test.sh tests/fm-pi-branch-live-e2e.test.sh tests/fm-pi-branch-extension.test.sh tests/fm-wake-queue.test.sh
bash bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 360 --json /Users/philipkirkbride/.no-mistakes/evidence/01M4T7GDD9T0QQZBJ8T889926Y/wake-queue-retest.json tests/fm-wake-queue.test.sh
```

The three Pi scripts exited 0 without skips. The first wake-queue invocation hit the self-imposed 180s bound near the end; the isolated 360s rerun exited 0 without skips.
[Initial command results](focused-tests.json), [initial log](focused-tests.log), [successful queue rerun](wake-queue-retest.json), [rerun log](wake-queue-retest.log).
This is a corrected validation time bound, not a target assertion failure. No timeout setting or source was changed.

All 13 live scenarios passed. The publication tree is clean, the tested full HEAD is unchanged, and all disposable worktree fixtures were removed. Verdict: go.
