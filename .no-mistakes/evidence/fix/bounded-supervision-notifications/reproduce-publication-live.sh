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

for source in "$ROOT"/bin/*; do
  name=${source##*/}
  case "$name" in fm-watch-arm.sh|fm-operational-input.sh) continue ;; esac
  ln -s "$source" "$repo/bin/$name"
done
ln -s "$ROOT/docs" "$repo/docs"
ln -s "$ROOT/.agents" "$repo/.agents"
ln -s "$ROOT/skills" "$repo/skills"
rm "$repo/bin/fm-wake-grant.sh"
cat > "$repo/bin/fm-wake-grant.sh" <<'GRANT'
#!/usr/bin/env bash
if [ "${1:-}" = publish ]; then
  count=$(cat "$FM_HOME/state/publish-attempts" 2>/dev/null || printf 0)
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_HOME/state/publish-attempts"
  if [ "$count" -eq 1 ]; then printf '1\n' > "$FM_HOME/state/.main-eligible-rows"; fi
  if [ "$count" -eq 2 ] && [ "$FM_RACE_MODE" = repeat ]; then printf '1\n2\n' > "$FM_HOME/state/.main-eligible-rows"; fi
fi
exec bash "$FM_REAL_ROOT/bin/fm-wake-grant.sh" "$@"
GRANT
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
const publicationsAtProvider=[];
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
  if(existsSync(`${home}/state/.branch-eligible-rows`))publicationsAtProvider.push(readFileSync(`${home}/state/.branch-eligible-rows`,"utf8"));
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
  additionalExtensionPaths: [process.env.WATCH_PLUGIN, `${process.env.FM_ROOT_OVERRIDE}/.pi/extensions/fm-branch-supervision.ts`],
  extensionFactories: [{
    name: "fm-event-contract-probe",
    factory: (pi) => {
      pi.events.on("fm-branch-supervision:dispatch",offer=>setTimeout(()=>{events.push({type:"branch_offer",accepted:offer.accepted});offer.settlement?.catch(error=>events.push({type:"branch_failure",text:String(error)}));},0));
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
releaseStream();
const queue="1\t1\tsignal\told.status\tsignal: old notification\n2\t2\tsignal\tfresh.status\tsignal: fresh notification\n3\t3\tsignal\tfresh.status\tsignal: another fresh notification\n";
writeFileSync(`${home}/state/old.meta`,"project=/approved\nwindow=fm-old\n");
writeFileSync(`${home}/state/fresh.meta`,"project=/approved\nwindow=fm-fresh\n");
writeFileSync(`${home}/state/.wake-queue`,queue);
await waitFor(()=>armRows("arm ")===1,"initial live session arm");
writeFileSync(process.env.FM_LIVE_WATCH_TRIGGER,"signal: fresh.status\n");
await waitFor(()=>has("user_message_start","FIRSTMATE WATCHER WAKE"),"watcher main fallback after real branch session finishes");
await session.waitForIdle();
writeFileSync(`${process.env.FM_TEST_EVIDENCE_DIR}/publication-${process.env.FM_RACE_MODE}-debug-events.json`,JSON.stringify(events,null,2));
const attempts=Number(readFileSync(`${home}/state/publish-attempts`,"utf8"));
if(attempts!==2)throw new Error(`Pi did not bound the publication retry to two attempts: ${attempts}`);
if(process.env.FM_RACE_MODE==="once"){
 if(publicationsAtProvider.length!==1||publicationsAtProvider[0]!=="2\n3\n")throw new Error(`fresh rows never reached the real branch provider interface: ${JSON.stringify(publicationsAtProvider)}`);
 if(readFileSync(`${home}/state/.main-eligible-rows`,"utf8")!=="1\n")throw new Error("main's claim changed");
}else{
 if(publicationsAtProvider.length!==0)throw new Error("repeat race prompted the branch");
 if(readFileSync(`${home}/state/.main-eligible-rows`,"utf8")!=="1\n2\n")throw new Error("repeat race changed main claim");
}
if(readFileSync(`${home}/state/.wake-queue`,"utf8")!==queue)throw new Error("publication or fallback acknowledged durable rows");
writeFileSync(`${process.env.FM_TEST_EVIDENCE_DIR}/publication-${process.env.FM_RACE_MODE}-events.json`,JSON.stringify({sdk:"1.1.0",attempts,publicationsAtProvider,events,queue,mainClaim:readFileSync(`${home}/state/.main-eligible-rows`,"utf8"),armLog:readFileSync(armLog,"utf8")},null,2));
await session.dispose();console.log(`PUBLICATION_${process.env.FM_RACE_MODE}_OK`);process.exit(0);
EOF
status=$?
cat "$TMP_ROOT/stream-output"
exit "$status"
