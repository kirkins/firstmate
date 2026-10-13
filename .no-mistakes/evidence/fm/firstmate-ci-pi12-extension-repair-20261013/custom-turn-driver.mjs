import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const requests = [];
const server = createServer(async (req, res) => {
  let body = "";
  for await (const chunk of req) body += chunk;
  requests.push(JSON.parse(body));
  res.writeHead(200, { "content-type": "text/event-stream" });
  const chunk = (delta, finish_reason) => `data: ${JSON.stringify({
    id: "custom-start-probe", object: "chat.completion.chunk", created: 1,
    model: "custom-start", choices: [{ index: 0, delta, finish_reason }],
  })}\n\n`;
  res.end(chunk({ role: "assistant", content: "CUSTOM_START_OK" }, null)
    + chunk({}, "stop") + "data: [DONE]\n\n");
});
await new Promise((ready) => server.listen(0, "127.0.0.1", ready));
const agentDir = resolve(process.env.PI_CODING_AGENT_DIR);
writeFileSync(`${agentDir}/models.json`, JSON.stringify({ providers: {
  "fm-custom-start": {
    baseUrl: `http://127.0.0.1:${server.address().port}/v1`,
    api: "openai-completions", apiKey: "disposable-local-provider",
    models: [{ id: "custom-start", name: "Custom start probe", contextWindow: 8192, maxTokens: 128 }],
  },
} }));
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const { DefaultResourceLoader, ModelRuntime, ModelRegistry, SessionManager, SettingsManager, createAgentSession } =
  await import(pathToFileURL(`${process.env.PI_PACKAGE_DIR}/dist/index.js`).href);
const events = [];
const errors = [];
const settings = SettingsManager.create(process.cwd(), agentDir);
const loader = new DefaultResourceLoader({
  cwd: process.cwd(), agentDir, settingsManager: settings,
  additionalExtensionPaths: [process.env.BRANCH_PLUGIN, process.env.WATCH_PLUGIN],
  noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
  extensionFactories: [{ name: "custom-start-observer", factory(pi) {
    pi.on("before_agent_start", (event) => {
      events.push({ messageType: event.messageType, hasPrompt: "prompt" in event });
    });
  } }],
});
await loader.reload();
const runtime = await ModelRuntime.create({ authPath: `${agentDir}/auth.json`, modelsPath: `${agentDir}/models.json` });
const registry = new ModelRegistry(runtime);
await registry.refresh();
const manager = SessionManager.create(process.cwd(), `${process.env.FM_HOME}/sessions`);
let session;
try {
  const created = await createAgentSession({
    cwd: process.cwd(), sessionManager: manager, settingsManager: settings,
    resourceLoader: loader, modelRuntime: runtime,
    model: registry.find("fm-custom-start", "custom-start"), noTools: "builtin",
  });
  session = created.session;
  assert.deepEqual(created.extensionsResult.errors, [], "both tracked extensions must load");
  assert.ok(session.getToolDefinition("fm_branch_processed"), "the branch extension must be registered");
  assert.ok(session.getToolDefinition("fm_watch_arm_pi"), "the watcher extension must be registered");
  await session.bindExtensions({ onError: (error) => errors.push(error) });
  await session.prompt("User request before custom turns");
  for (let index = 1; index <= 3; index++) {
    await session.sendCustomMessage({ customType: "fm-live-custom-probe", content: `Custom turn ${index}`, display: true }, { triggerTurn: true });
  }
  await session.prompt("User request after custom turns");
  assert.deepEqual(errors, [], "custom turns must not produce caught extension errors");
  assert.deepEqual(events, [
    { messageType: "user", hasPrompt: true },
    ...Array.from({ length: 3 }, () => ({ messageType: "custom", hasPrompt: false })),
    { messageType: "user", hasPrompt: true },
  ]);
  assert.equal(requests.length, 5, "each turn must reach the real provider transport");
  const reopened = SessionManager.open(manager.getSessionFile());
  const entries = reopened.getEntries();
  const messages = entries.filter((entry) => entry.type === "message").map((entry) => entry.message);
  assert.equal(messages.filter((message) => message.role === "user").length, 2);
  assert.equal(entries.filter((entry) => entry.type === "custom_message" && entry.customType === "fm-live-custom-probe").length, 3);
  assert.equal(messages.filter((message) => message.role === "assistant" && message.stopReason === "stop").length, 5);
  await session.exportToHtml(`${process.env.EVIDENCE_DIR}/custom-turns.html`);
  session.exportToJsonl(`${process.env.EVIDENCE_DIR}/custom-turns.jsonl`);
  writeFileSync(`${process.env.EVIDENCE_DIR}/custom-turn-events.json`, JSON.stringify({sdk: "1.2.0", events, errors, providerRequests: requests.length, persistedMessages: entries.map(entry => entry.type === "message" ? {type: entry.type, role: entry.message.role, content: entry.message.content} : entry.type === "custom_message" ? {type: entry.type, customType: entry.customType, content: entry.content} : {type: entry.type})}, null, 2));
  console.log("CUSTOM_START_OK: 2 user prompts, 3 prompt-less custom turns, 5 HTTP completions, no extension errors; session reopened and exported");
} finally {
  session?.dispose();
  server.closeAllConnections();
  await new Promise((done) => server.close(done));
}
process.exit(0);