# Learnings

## Emergency SSH access to k3s-master-1 (established 2026-10-10)

`ssh k3s-master-1` (root@10.200.0.1) with the dedicated key
~/.ssh/id_ed25519_k3s_emergency (no passphrase, single purpose). The public key
was authorized on the node via a one-shot privileged pod mounting host / and
appending to /root/.ssh/authorized_keys (idempotent grep guard) - the pattern
to re-use if another node ever needs it. Revocation: delete that one line from
/root/.ssh/authorized_keys. Verified working 2026-10-10 (used for kubelet log
diagnosis of the runner Init wedge). <!--a:2026-10-10-->

## Dead-replica debris on k3s (2026-10-10)

The opencode-azure-burst-controller deployment carries one live replica plus
one ContainerStatusUnknown twin (142 historical restarts); the dead twin is
safe to delete (never the live one) and renders as a forever-"running" ghost
on the dashboard until the orphan-aging fixes land. The forgejo-isolated
single-job runner pods can wedge as idle pollers ("received no task" every 5s
indefinitely) - deleting the owning Job cleans them; the per-minute CronJob
respawns healthy ones. <!--a:2026-10-10-->

# Fleet service access
<!-- memory tiers: see the stow skill -->

The Forgejo MCP offers repository, issue, and pull-request context through the
existing scoped bot integration. Git delivery uses the machine's separate SSH
identity. Use `lobbykit-forgejo` for operator API actions; it reads its token from
Linux Secret Service. Never print or pass tokens as command arguments. This is
Forgejo at git.lobbykit.net, so use its API/helper for delivery rather than
assuming GitHub tooling applies. <!--a:2026-10-09-->

The Hermes MCP offers `submit_job`, `get_job`, and `stop_job`. Use it for an
explicitly requested Hermes task, retain the returned signed job ID, and check
the result before reporting completion. These are asynchronous jobs; the
existing `hermes_ask` conversation bridge is a separate integration. <!--a:2026-10-06-->

GLM-5.3 and GLM-5.3-Flash use `lobbykit-zai` and the cluster gateway at
http://127.0.0.1:18080/v1. The upstream z.ai key stays in Kubernetes.
Check/reconnect with `systemctl --user status/restart zai-cluster-gateway`. <!--a:2026-10-06-->

# Inventory scouts must cross-reference held credentials

2026-10-10: the Hermes tooling scout cataloged providers by auth requirement
but never checked which keys the fleet already holds; the captain caught it
(brave-search-canary secrets sat in two namespaces, plus Z.ai and OpenRouter
keys). Brief-writing rule: any capability-inventory scout must be told to
cross-reference existing credentials (cluster secrets, credential store)
against provider requirements before recommending anything keyed. <!--a:2026-10-10-->

# Fresh-worktree launch prompts (pi trust picker)

2026-10-10: fresh pi spawns in never-used treehouse paths stall at a launch
picker (trust/theme) until dismissed; the fix that works is pre-trust the new
worktree path in ~/.pi/agent/trust.json immediately after spawn, then
fm-control interrupt (clears the picker/composer) followed by fm-send with a
begin-the-task line. A bare doorbell alone works only when the composer reads
empty. Consider pre-trusting the worktree path before the spawn resolves as a
future improvement. <!--a:2026-10-10-->

# Codex worker trust dialogs differ from pi

2026-10-10: a fresh codex worktree shows a directory-trust dialog that the
pi-style interrupt+nudge pattern does NOT safely answer - typed text may
decline it. Correct handling per harness-adapters/references/harness/codex.md:
accept with Enter and verify instructions begin processing; hook-trust modals
are unanswerable by design (crew launches disable the hook layer). When a
codex spawn stalls, peek the pane HEAD (the composer tail can read idle while
work proceeds above). The captain resolved one manually by clicking trust.
<!--a:2026-10-10-->

# Media-key routing fix location

2026-10-10: the play/pause dormant-session misfire was fixed live in the
captain's local omarchy plugin clone ~/.config/omarchy/plugins/kirkins.media
(outside any fleet repo; no repo change). The captain's on-glass test passed.
If media keys misroute again, check that clone first. <!--a:2026-10-10-->

# Local memory exhaustion

2026-10-06: Kernel logs record ShellCheck OOM kills at 13:38:18 and 14:01:15 America/Lima, each after roughly 4.2 GiB resident allocation.
The containing terminal scopes reported oom-kill, and Herdr logged shutdowns and worker hangups at the same times; no coredumps were recorded.
The user systemd manager reports DefaultOOMPolicy=stop, so work sharing a terminal scope can be interrupted together.
Local implementation changes survived both interruptions; worker presence must be checked separately from restored terminal panes.
Avoid repeating unbounded ShellCheck sweeps on this 8 GB machine; keep heavy checks sequential and resource bounded without changing global settings or skipping required validation. <!--a:2026-10-06-->

2026-10-09: The vpinball2d evaluation build ran uncapped; an SMC forced shutdown
ended the boot at 11:05 and an uncapped rustc (2.3 GiB anon RSS, 4.7 GiB
total-vm, terminal scope) was OOM-killed at 14:15 after the reboot. Caps are
now mandatory on every heavy launch regardless of which agent session starts
it: one heavy job machine-wide, cargo -j2, and a memory cap via
systemd-run --user --scope -p MemoryMax=4G. Build-task briefs and steers carry
the caps explicitly. <!--a:2026-10-09-->

# No-mistakes worker handoff pattern

2026-10-09: Both pi/herdr ship workers today reported `done` at the
implementation commit with offline tests green but without starting the
no-mistakes validation run (dashboard probe fix, telegram voice mode). Expected
behavior: after a ship reports done-at-commit, check bin/fm-crew-state.sh for an
active validation line; if absent, relaunch with a note instructing the same
worker to trigger and drive the pipeline - the relaunch path recovers this
cleanly with worktree and commits intact. <!--a:2026-10-09-->

# Cluster node is inference-critical

2026-10-09 night incident: k3s-master-1 (the ONLY node) went NotReady and the
Kubernetes API became unreachable after the vpinball2d cross-proof Job ran with
limits cpu 6 / memory 5Gi on an already-loaded node (13+ GiB of 15.2 used,
~40% CPU). The job's go/no-go gate checked memory headroom only - CPU was the
missed dimension. The node also hosts the z.ai inference egress that every
local agent (all pi/glm workers plus firstmate itself) depends on via the local
zai-cluster-gateway; inference survived the incident but the node is
production-critical for agent operation, not a build playground. There is no
SSH key onto the node yet (kirkins@10.200.0.1 refuses publickey); a dedicated
emergency key ~/.ssh/id_ed25519_k3s_emergency with `ssh k3s-master-1` (root)
was prepared 2026-10-09 pending one API window to authorize it on the node.
Strategy going forward: cluster build jobs gate on BOTH cpu and memory (cap
cpu at 2 on this node), heavy cluster work waits for genuine headroom on both,
no new cluster load while the node is degraded, and kill-commands plus the key
authorization land in the first answering API window. <!--a:2026-10-09-->

# dfr-deck local delivery posture

2026-10-09: A landed local-only dfr-deck merge is NOT testable until the daemon
binary is rebuilt from master and installed; the running Touch Bar service uses
/usr/local/libexec/tiny-dfr-multibar (drop-in override of system tiny-dfr.service,
README section "Reversible device installation after review"). Update flow used
2026-10-09: capped release build (CARGO_TARGET_DIR outside the repo, -j2,
memory-capped scope), backup old binary under /var/lib/tiny-dfr-multibar-rollback-*/,
`sudo install -m 0755 ... /usr/local/libexec/tiny-dfr-multibar`, `sudo systemctl
restart tiny-dfr.service`; live /etc/tiny-dfr/config.toml is the captain's config.
CRITICAL 2026-10-10 follow-up: when the change ADDS config-expressed UI (a new
button, a color knob, a behavior key), the live config must also gain the new
entry or the feature is invisible - this bit twice in one night (blue color,
visualizer button): after every install, diff the repo's
share/tiny-dfr/multibar.toml example against the live config for the touched
layer and port the new keys before claiming it live. Delete the rollback copy
once the captain confirms the update. <!--a:2026-10-09-->

# Cluster AI issue-worker fleet

2026-10-06: Learned through two completed Hermes Jobs MCP requests; the complete corrected guide and original evidence are in data/cluster-worker-fleet-guide/report.md.
The cluster's repository execution route is Forgejo issues; Hermes Jobs submit_job/get_job/stop_job is a separate request-and-result interface, and the Herdr advisory broker is another service.
The worker engine is in hermes/opencode-k8s:forgejo_issue_worker.py; the historical opencode name covers multiple harness/model routes.
Eligible repositories need issue_worker.watch_repos membership, an execution_policy.repositories entry, existing labels, and a working worker route in hermes/opencode-config:config/opencode/issue-worker.yaml.
Use self-contained feature, bug, or research issues with explicit scope, acceptance criteria, relevant tests and non-goals; the reconciler discovers labeled issues without requiring a webhook.
The Forgejo MCP accepts existing label names and resolves IDs; raw Forgejo API label payloads use numeric IDs.
Dependencies gate on issue closure, so verify delivered commits or reports before relying on a predecessor's result.
Build chained epics with self-contained child tickets linked through depends_on; independent tickets can use parallel fleet capacity while prerequisite chains remain gated.
Issue comments are not reliable mid-attempt steering; scope changes belong between attempts, and stop_job does not control Forgejo issue workers.
Read current lane status and issue comments for progress, deduplicate against open and recent closed tickets, and verify current repository policy and available toolchains before dispatch.
The workstation has an authenticated Forgejo MCP and lobbykit-forgejo credential path; the Hermes pod's tool inventory does not establish this home's capabilities.
At the teaching snapshot dfr-deck was absent from the watch list and execution policy, while fitforge-ios and opencode-k8s were present; recheck enrollment before assigning new work.
FitForge code work can use Linux workers, with native qualification continuing through the accepted Xcode Cloud workflow; local Omarchy, host files and hardware operations remain local.
Queue ordering and review-required semantics for research-only issues were not conclusively verified; consult the guide's uncertainties rather than assuming them.
 <!--a:2026-10-06-->

# Fork sync conventions

2026-10-07: The kirkins/firstmate fork intentionally keeps README and
CONTRIBUTING content-identical to upstream (no fork re-pointing of clone URLs,
badges, or PR flow) to keep upstream sync pulls friction-free; the fork is a
private carry-line, not a presentation identity. Clean syncs: fetch upstream,
merge, run affected suites bounded (FM_LINT_JOBS=1), push fork. Conflicting
syncs: dispatch a task shaped like firstmate-fork-sync-237e1cf3 (recipe in its
data directory future-syncs.md). <!--a:2026-10-07-->

# Local Rust toolchain

2026-10-07: This machine now has a shared user-level rustup toolchain
(cargo/rustc on PATH via /usr/bin/cargo, verified 1.99.0). Rust tasks should
use it directly instead of provisioning task-local toolchains; the per-task
toolchain duplication pattern (two Touch Bar tasks each built one, ~3.9G) is
retired. Rebuildable target caches still belong under task data dirs and get
cleaned at teardown. <!--a:2026-10-07-->

2026-10-10 runner-restoration lesson: three drift layers kept CI dead after the pool
returned - registration labels (declared at registration, not config), the repo
manifest's replicas:0 (kubectl apply of canonical manifests resets live scale-ups;
scale AFTER applying), and the config-template ConfigMap label list (live CM
predated merged PRs; patch the CM then rollout-restart). Verification command:
the pod log line 'declared successfully' shows the true label set; 'received no
task' with a queued job means a label/connection mismatch. <!--a:2026-10-10-->

## Mac secondmate registered (2026-10-10)

The remote secondmate `mac` (host firstmate-mac) was provisioned out-of-band by
the captain's Codex session and registered in data/secondmates.md by the seed
flow; its endpoint is alive and idle-by-default, scope is macOS/iOS
build-test-validation (FitForge focus), GLM via lobbykit-zai only. The captain
cleared it for routed work on 2026-10-10. Route through marked status returns,
 Rescoped to general capacity the same day at the captain's word (FitForge stays a listed clone, not the focus). The remote home's data/charter.md still carries the original seeded text (fm-on.sh refuses hand edits by design); the registry and data/mac/brief.md here are the rescoped source of truth, and the live mate received the amendment through its inbox. A future reseed/relaunch path should push the rescoped charter file. <!--a:2026-10-10-->


# zai gateway deployment uses generated ConfigMap names (2026-10-10 outage)

The opencode/zai-coding-gateway Deployment's live script volume normally
references a GENERATED ConfigMap name (e.g. opencode-zai-coding-gateway-script-6h2dmffb4b)
produced by whatever publishes the gateway code; the canonical manifest
17d-zai-coding-gateway.yaml carries the UNQUALIFIED name
opencode-zai-coding-gateway-script. A raw kubectl apply of the canonical
manifest onto the live deployment reset the volume ref to the static name,
which did not exist: the Recreate rollout killed the serving replica and the
new pod sat ~50 min in FailedMount (configmap not found), taking all GLM
inference down fleet-wide (three no-mistakes runs died on provider connection
errors and needed resume steers). Recovery (Codex, per the incident handoff):
create only the missing static-name ConfigMap from the verified working
generated one (SHA-256 recorded in its annotations); the scheduled pod then
went Ready with no deployment patch. Never raw-apply canonical manifests over
generator-managed live state in opencode-k8s - same class as the
runner-restoration scale-reset lesson. Validate referenced nonoptional
ConfigMaps exist and check rollout success plus live service endpoints after
any gateway deployment change; a successful apply alone is insufficient. The
static-name CM is a recovery compatibility artifact until the durable path
settles (prevention task: opencode-k8s-gateway-apply-safety-20261010).
<!--a:2026-10-10-->
