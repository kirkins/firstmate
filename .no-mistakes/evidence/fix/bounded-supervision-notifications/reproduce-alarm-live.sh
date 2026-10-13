#!/usr/bin/env bash
# Opt-in live guard for the Pi supervision-branch extension against the REAL
# installed @earendil-works/pi-coding-agent SDK (no stubs): the branch session
# is created through the real DefaultResourceLoader/SessionManager/
# createAgentSession surface, the custom bash and fm_branch_report tool
# definitions must be accepted by the real tool registry, the session file and
# pointer must persist on disk, and - because the isolated agent dir carries no
# credentials and no models - the branch's first prompt must reject its offer
# settlement so the watcher retains ownership and delivers the wake to main
# against the real SDK. It also resolves the supervision-branch model pin
# through the branch's REAL ModelRuntime, so a pin the vendor cannot resolve is
# proven to refuse the build rather than silently running the branch on main's
# model. A second branch probe intercepts the incident's post-construction 429
# in-process and proves that Pi's normally settled error turn returns ownership
# to the watcher. The model-precedence probe pins the vendor contract that the
# model pin rests on:
# an explicit model must beat the model a reopened session recorded, proven
# against a local, never-contacted fake provider. The effort-precedence probe
# does the same for the supervision-branch effort pin: Pi's own supported-level
# list is what the picker offers, Pi's own clamp is what lowers a level a model
# cannot run, and an explicit thinking level must beat the level a reopened
# session recorded.
#
# No provider call leaves the machine. The first branch probe points
# PI_CODING_AGENT_DIR at an empty directory, so it reads no credentials and
# model resolution stays empty by construction. The 429 probe intercepts its
# only request before transport, and the precedence probes read only a local
# placeholder key for their never-contacted fake provider. Run after
# every Pi upgrade and before trusting refreshed per-harness evidence
# (docs/verification/runtime-backends.md).
set -u

# shellcheck source=tests/lib.sh
. "/Users/philipkirkbride/.no-mistakes/worktrees/23fcc4135189/01M4T7GDD9T0QQZBJ8T889926Y/tests/lib.sh"

fm_live_gate opt-in FM_PI_BRANCH_LIVE_E2E npm jq node
export NODE_NO_WARNINGS=1

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  fail "Pi package absent: the live branch guard needs @earendil-works/pi-coding-agent installed (FM_PI_PACKAGE_DIR to override)"
fi
PI_VERSION=$(jq -r '.version' "$PI_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')

TMP_ROOT=$(fm_test_tmproot fm-pi-branch-live)
repo="$TMP_ROOT/repo"
home="$TMP_ROOT/home"
agentdir="$TMP_ROOT/agent-dir"
mkdir -p "$repo/.pi/extensions/lib" "$repo/node_modules/@earendil-works" \
  "$home/state" "$home/config" "$agentdir"
cp "$ROOT/.pi/extensions/fm-branch-supervision.ts" "$repo/.pi/extensions/fm-branch-supervision.ts"
cp "${FM_PROOF_WATCH_SOURCE:-$ROOT/.pi/extensions/fm-primary-pi-watch.ts}" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$repo/.pi/extensions/lib/fm-branch-model-picker.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
mkdir -p "$repo/bin"
cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "$FM_LIVE_WATCH_LOG"
  exit 0
fi
printf 'arm pid=%s\n' "$$" >> "$FM_LIVE_WATCH_LOG"
count=$(grep -c '^arm ' "$FM_LIVE_WATCH_LOG")
trap 'printf "retired=%s\n" "$count" >> "$FM_LIVE_WATCH_LOG"; exit 0' TERM INT
if [ "$count" -ge 3 ] && [ -e "$FM_LIVE_WATCH_TRIGGER.block" ]; then
  printf 'blocked=%s\n' "$count" >> "$FM_LIVE_WATCH_LOG"
  while [ -e "$FM_LIVE_WATCH_TRIGGER.block" ]; do sleep 0.02; done
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=alarm-%s\n' "$$" "$count"
printf 'ready=%s\n' "$count" >> "$FM_LIVE_WATCH_LOG"
while :; do
  if [ -e "$FM_LIVE_WATCH_TRIGGER" ]; then
    reason=$(cat "$FM_LIVE_WATCH_TRIGGER")
    rm -f "$FM_LIVE_WATCH_TRIGGER"
    printf '%s\n' "$reason"
    case "$reason" in *FAILED*) exit 2 ;; esac
    exit 0
  fi
  sleep 0.02
done
SH
chmod +x "$repo/bin/fm-operational-input.sh" "$repo/bin/fm-watch-arm.sh"
ln -s "$PI_PACKAGE_DIR" "$repo/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$repo/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" "$repo/node_modules/@earendil-works/pi-ai"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$repo/node_modules/typebox"

streamdir="$TMP_ROOT/stream-agent-dir"
streamhome="$TMP_ROOT/stream-home"
mkdir -p "$streamdir" "$streamhome/state" "$streamhome/config" "$TMP_ROOT/stream-sessions"
cat > "$streamdir/models.json" <<'JSON'
{
  "providers": {
    "fm-live-stream": {
      "baseUrl": "https://fm-live-stream.invalid/v1",
      "api": "openai-completions",
      "apiKey": "fm-live-placeholder",
      "models": [
        { "id": "fm-live-stream-model", "name": "fm live stream", "contextWindow": 8192, "maxTokens": 512 }
      ]
    }
  }
}
JSON
WATCH_PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" \
  FM_HOME="$streamhome" FM_ROOT_OVERRIDE="$repo" \
  FM_LIVE_WATCH_LOG="$TMP_ROOT/stream-watch.log" FM_LIVE_WATCH_TRIGGER="$TMP_ROOT/stream-watch.trigger" \
  FM_LIVE_SESSIONS="$TMP_ROOT/stream-sessions" \
  PI_CODING_AGENT_DIR="$streamdir" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
  node --input-type=module > "$TMP_ROOT/stream-output" 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const home = resolve(process.env.FM_HOME);
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const pkg = resolve(process.env.PI_PACKAGE_DIR);
const { DefaultResourceLoader, ModelRegistry, ModelRuntime, SessionManager, SettingsManager, createAgentSession } =
  await import(pathToFileURL(`${pkg}/dist/index.js`).href);

// The local fake provider: the first completion streams one token and then
// holds its stream open until the probe releases it; later ones finish at once.
let completions = 0;
let releaseStream = () => {};
const streamHeld = new Promise((release) => {
  releaseStream = release;
});
let holdNextCompletion = false;
let releaseEscapeStream = () => {};
const escapeStreamHeld = new Promise((release) => {
  releaseEscapeStream = release;
});
const chunk = (delta, finish) => `data: ${JSON.stringify({
  id: "fm-live-stream",
  object: "chat.completion.chunk",
  created: 1,
  model: "fm-live-stream-model",
  choices: [{ index: 0, delta, finish_reason: finish }],
  ...(finish ? { usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } } : {}),
})}\n\n`;
globalThis.fetch = async (input) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  if (!url.startsWith("https://fm-live-stream.invalid/")) {
    throw new Error(`unexpected network request in provider-free guard: ${url}`);
  }
  completions += 1;
  const hold = completions === 1 ? streamHeld : holdNextCompletion ? escapeStreamHeld : Promise.resolve();
  holdNextCompletion = false;
  const encoder = new TextEncoder();
  const body = new ReadableStream({
    async start(controller) {
      controller.enqueue(encoder.encode(chunk({ role: "assistant", content: "OK" }, null)));
      await hold;
      controller.enqueue(encoder.encode(chunk({}, "stop")));
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      controller.close();
    },
  });
  return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
};

const events = [];
const userText = (content) => typeof content === "string"
  ? content
  : content.filter((part) => part.type === "text").map((part) => part.text).join("\n");
const agentDir = resolve(process.env.PI_CODING_AGENT_DIR);
const settings = SettingsManager.create(process.cwd(), agentDir);
const loader = new DefaultResourceLoader({
  cwd: process.cwd(),
  agentDir,
  settingsManager: settings,
  additionalExtensionPaths: [process.env.WATCH_PLUGIN],
  extensionFactories: [{
    name: "fm-event-contract-probe",
    factory: (pi) => {
      pi.on("before_agent_start", (event) => {
        events.push({ type: "before_agent_start", text: event.prompt });
      });
      pi.on("message_start", (event) => {
        if (event.message.role !== "user") return;
        events.push({ type: "user_message_start", text: userText(event.message.content) });
      });
      pi.on("input", (event) => {
        events.push({ type: "input", text: event.text, source: event.source, streamingBehavior: event.streamingBehavior });
      });
      pi.on("agent_settled", (event) => {
        events.push({ type: "agent_settled", aborted:event.aborted });
      });
    },
  }],
  noExtensions: true,
  noSkills: true,
  noPromptTemplates: true,
  noThemes: true,
  noContextFiles: true,
});
await loader.reload();
const runtime = await ModelRuntime.create({
  authPath: `${agentDir}/auth.json`,
  modelsPath: `${agentDir}/models.json`,
});
const registry = new ModelRegistry(runtime);
await registry.refresh();
const model = registry.find("fm-live-stream", "fm-live-stream-model");
if (!model) throw new Error("the real registry did not resolve the local streaming model");
const { session } = await createAgentSession({
  cwd: process.cwd(),
  sessionManager: SessionManager.create(process.cwd(), resolve(process.env.FM_LIVE_SESSIONS)),
  settingsManager: settings,
  resourceLoader: loader,
  modelRuntime: runtime,
  model,
  noTools: "builtin",
});

const armLog = process.env.FM_LIVE_WATCH_LOG;
const armRows = (prefix) => existsSync(armLog)
  ? readFileSync(armLog, "utf8").split(/\n/).filter((line) => line.startsWith(prefix)).length
  : 0;
const has = (type, text) => events.some((event) => event.type === type && (text === undefined || event.text.includes(text)));
const settledRuns = () => events.filter((event) => event.type === "agent_settled").length;
const waitFor = async (predicate, label) => {
  for (let i = 0; i < 600; i += 1) {
    const failure = events.find((event) => event.type === "prompt_error");
    if (failure) throw new Error(`the real session rejected its prompt: ${failure.text}`);
    if (predicate()) return;
    await new Promise((tick) => setTimeout(tick, 50));
  }
  throw new Error(`timeout waiting for ${label}; events=${JSON.stringify(events)}`);
};

await session.bindExtensions({onError:error=>events.push({type:"extension_error",text:JSON.stringify(error)})});
const mode = process.env.FM_ALARM_MODE;
const checkpoints=[];
const pause=()=>new Promise(resolve=>setTimeout(resolve,250));
const armLines=()=>readFileSync(armLog,"utf8").trim().split("\n");
const inputRows=()=>events.filter(e=>e.type==="input" && e.source==="extension");
const consumedRows=()=>events.filter(e=>e.type==="user_message_start" && e.text.includes("FIRSTMATE WATCHER WAKE"));
const touch=(suffix="")=>writeFileSync(`${process.env.FM_LIVE_WATCH_TRIGGER}${suffix}`,"trigger\n");
const armTool=session.getToolDefinition("fm_watch_arm_pi");
const armed=await armTool.execute("alarm-live-arm",{},undefined,undefined,{});
if(!armed.details?.ok) throw new Error(JSON.stringify(armed));
await waitFor(()=>armRows("arm ")===1,"first arm");
session.prompt("Human input before the first interruption.").catch(error=>events.push({type:"prompt_error",text:String(error)}));
await waitFor(()=>completions===1 && session.isStreaming,"held human turn");
const queue="1\t1\tcheck\talarm-one\tfirst durable event\n2\t2\tcheck\talarm-two\tsecond durable event\n";
writeFileSync(`${home}/state/.wake-queue`,queue);
writeFileSync(process.env.FM_LIVE_WATCH_TRIGGER,"signal: retained alarm invitation\n");
await waitFor(()=>session.getFollowUpMessages().length===1 && armRows("arm ")===2,"one pending routine invitation");
const anchor=session.getFollowUpMessages()[0];
if(!anchor.includes("signal: retained alarm invitation")) throw new Error("wrong anchor");
const consumed=mode==="consumed-exhaustion";
{
  const cleared=session.clearQueue();
  if(cleared.followUp[0]!==anchor)throw new Error("clearQueue lost anchor");
  const stopped=session.abort(); releaseStream(); await stopped;
  await waitFor(()=>settledRuns()===1,"first real abort");
}
touch(".block");
writeFileSync(process.env.FM_LIVE_WATCH_TRIGGER,consumed?"watcher: FAILED - forced successor outage\n":"signal: fresh event starts replay restoration\n");
await waitFor(()=>armLines().includes("blocked=3"),"blocked successor readiness");
if(consumed){
  await session.prompt("Human boundary resumes previously stopped monitoring.");
  await waitFor(()=>readFileSync(`${home}/state/.watch-extension.log`,"utf8").split("restore attempt=0").length>=3,"replay restoration waiting on the existing unready successor");
  await session.prompt(anchor);
  await waitFor(()=>consumedRows().some(e=>e.text===anchor),"actual exact message_start consumption during readiness");
  await session.waitForIdle();
  checkpoints.push({stage:"old routine consumed during delayed readiness",consumed:consumedRows(),armLog:armLines()});
}else{
  holdNextCompletion=true;
  session.prompt("Human input during delayed replay restoration.").catch(error=>events.push({type:"prompt_error",text:String(error)}));
  await waitFor(()=>completions===2 && session.isStreaming,"second human stream during readiness");
  const stopped=session.abort(); releaseEscapeStream(); await stopped;
  await waitFor(()=>settledRuns()===2,"second real abort during readiness");
  checkpoints.push({stage:"second Escape during delayed readiness",completions,pending:session.pendingMessageCount,inputCount:inputRows().length,armLog:armLines()});
}
if(mode==="aborted-ready"){
  unlinkSync(`${process.env.FM_LIVE_WATCH_TRIGGER}.block`);
  await waitFor(()=>armLines().includes("ready=3"),"release successor readiness");
  await pause();
  if(completions!==2 || inputRows().length!==1 || session.pendingMessageCount!==0)throw new Error("readiness continuation undid Escape");
  checkpoints.push({stage:"readiness released without automatic prompt",completions,pending:session.pendingMessageCount,inputCount:inputRows().length});
  writeFileSync(process.env.FM_LIVE_WATCH_TRIGGER,"signal: genuine wake after second Escape\n");
  await waitFor(()=>consumedRows().some(e=>e.text===anchor),"later genuine wake recovers retained routine invitation");
  await session.waitForIdle(); await pause();
  if(consumedRows().filter(e=>e.text===anchor).length!==1)throw new Error("anchor lost or duplicated");
}else{
  const extensionLog=`${home}/state/.watch-extension.log`;
  await waitFor(()=>existsSync(extensionLog)&&readFileSync(extensionLog,"utf8").includes("restore exhausted attempts=2 outcome=hand-to-main"),"bounded restoration exhausted");
  await waitFor(()=>armLines().includes("retired=3")&&armLines().includes("retired=4"),"both failed successors retired");
  const expectedAlarm="watcher: FAILED - Pi extension could not restore watcher continuity after 1 retries";
  if(consumed){
    await waitFor(()=>consumedRows().some(e=>e.text.includes(expectedAlarm)),"fresh alarm reaches main after old invitation consumption");
    await session.waitForIdle();
    if(consumedRows().filter(e=>e.text===anchor).length!==1)throw new Error("consumed routine redelivered");
    if(consumedRows().filter(e=>e.text.includes(expectedAlarm)).length!==1)throw new Error("fresh alarm lost or duplicated");
    checkpoints.push({stage:"fresh alarm despite original consumption",messages:consumedRows(),arms:armLines()});
  }else{
    await pause();
    if(completions!==2 || inputRows().length!==1 || session.pendingMessageCount!==0)throw new Error("exhausted restoration undid Escape");
    checkpoints.push({stage:"exhausted alarm deferred after Escape",completions,pending:session.pendingMessageCount,inputCount:inputRows().length,arms:armLines()});
  }
  if(armRows("arm ")!==4)throw new Error("restoration retry was not bounded");
  unlinkSync(`${process.env.FM_LIVE_WATCH_TRIGGER}.block`);
  await session.reload();
  if(!consumed){
    await waitFor(()=>consumedRows().some(e=>e.text.includes(expectedAlarm)),"replacement replays fresh failure details");
    await session.waitForIdle();
    if(consumedRows().filter(e=>e.text.includes(expectedAlarm)).length!==1)throw new Error("replacement lost or duplicated fresh alarm");
    if(!consumedRows().find(e=>e.text.includes(expectedAlarm)).text.includes("could not verify a ready successor watcher"))throw new Error("replacement lost readiness failure detail");
  }else{
    await pause();
    if(consumedRows().filter(e=>e.text.includes(expectedAlarm)).length!==1)throw new Error("replacement replayed consumed alarm");
  }
  checkpoints.push({stage:"real extension reload recovery",messages:consumedRows(),armLog:armLines()});
}
if(readFileSync(`${home}/state/.wake-queue`,"utf8")!==queue)throw new Error("recovery mutated durable queue");
writeFileSync(`${process.env.FM_TEST_EVIDENCE_DIR}/${mode}-events.json`,JSON.stringify({mode,sdk:"1.1.0",checkpoints,events,armLog:armLines(),durableQueue:queue},null,2));
await session.exportToHtml(`${process.env.FM_TEST_EVIDENCE_DIR}/${mode}-session.html`);
await session.dispose();
console.log("ALARM_OK");
process.exit(0);
EOF
status=$?
out=$(cat "$TMP_ROOT/stream-output")
if [ "$status" -ne 0 ]; then
  cp "$TMP_ROOT/stream-watch.log" "$FM_TEST_EVIDENCE_DIR/$FM_ALARM_MODE-debug-arms.log"
  cp "$streamhome/state/.watch-extension.log" "$FM_TEST_EVIDENCE_DIR/$FM_ALARM_MODE-debug-extension.log"
  printf '%s\n' "$out"
  exit "$status"
fi
printf '%s: %s\n' "$FM_ALARM_MODE" "$out"
