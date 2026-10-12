// fm-gateway-stub.mjs - disposable local OpenAI-compatible gateway for live
// validation of the supervision-branch provider fix.
//
// Emulates the production lobbykit-zai/glm-5.3 gateway's fail-closed field
// validation: any chat-completions request whose JSON body carries a field the
// gateway does not allow (the production incident: prompt_cache_key) is
// rejected with 400 {"type":"field_not_allowed"} - the exact production
// failure signature from the operational review. Requests without the field
// are served with a scripted SSE completion that drives a real supervision
// turn (drain -> fm_branch_report -> ack) or a real main turn.
//
// Env:
//   FM_GW_PORT      port to listen on (127.0.0.1)
//   FM_GW_LOG       JSONL request log path (append)
//   FM_GW_MODE      mode file path; file content controls behavior:
//                     normal - allowlist enforcement only (production gateway)
//                     fail   - reject every BRANCH request with the same 400
//                              (models the "every helper attempt rejected"
//                              incident state), main requests still served
import { createServer } from "node:http";
import { appendFileSync, readFileSync } from "node:fs";

const PORT = Number(process.env.FM_GW_PORT || 0);
const LOG = process.env.FM_GW_LOG;
const MODE_FILE = process.env.FM_GW_MODE;

// The gateway's field allowlist. The production gateway rejected
// prompt_cache_key on this route; that is the contract being emulated.
const FORBIDDEN_FIELDS = ["prompt_cache_key"];

const log = (entry) => {
  const line = JSON.stringify({ ts: new Date().toISOString(), ...entry });
  if (LOG) appendFileSync(LOG, line + "\n");
  console.log(line);
};

const mode = () => {
  try {
    return (readFileSync(MODE_FILE, "utf8") || "normal").trim() || "normal";
  } catch {
    return "normal";
  }
};

const sse = (res, chunks) => {
  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
  for (const c of chunks) res.write(`data: ${JSON.stringify(c)}\n\n`);
  res.write("data: [DONE]\n\n");
  res.end();
};

const chunk = (model, delta, finish, usage) => ({
  id: "fm-gw",
  object: "chat.completion.chunk",
  created: 1,
  model,
  choices: [{ index: 0, delta, finish_reason: finish }],
  ...(usage ? { usage } : {}),
});

const textChunks = (model, text) => [
  chunk(model, { role: "assistant", content: text }, null),
  chunk(model, {}, "stop", { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }),
];

const toolChunks = (model, name, args) => [
  chunk(model, { role: "assistant", content: "" }, null),
  chunk(model, { tool_calls: [{ index: 0, id: "call_fm_gw", type: "function", function: { name, arguments: JSON.stringify(args) } }] }, null),
  chunk(model, {}, "tool_calls", { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }),
];

const textOf = (content) =>
  typeof content === "string"
    ? content
    : Array.isArray(content)
      ? content.filter((p) => p && p.type === "text").map((p) => p.text).join("\n")
      : "";

// ---- per-wake segment: messages after the last user message carrying marker ----
const segmentAfter = (msgs, marker) => {
  let idx = -1;
  msgs.forEach((m, i) => {
    if (m.role === "user" && String(textOf(m.content)).includes(marker)) idx = i;
  });
  return idx < 0 ? msgs : msgs.slice(idx + 1);
};

// ---- branch conversation derivation (stateless, per wake segment) ----
const branchTurn = (body) => {
  const msgs = body.messages || [];
  const firstUser = msgs.find((m) => m.role === "user");
  const wakeMatch = String(textOf(firstUser?.content)).match(/FIRSTMATE SUPERVISION WAKE: (.*)/);
  const wakeLine = wakeMatch ? wakeMatch[1].split("\n")[0].trim() : "";
  const taskMatch = wakeLine.match(/signal: (\S+)/);
  const task = taskMatch ? (taskMatch[1].split("/").pop() || "").replace(/\.status$/, "") : "fleet";
  const seg = segmentAfter(msgs, "FIRSTMATE SUPERVISION WAKE");
  const toolMsgs = seg.filter((m) => m.role === "tool");
  const hasReportCall = seg.some(
    (m) => m.role === "assistant" && Array.isArray(m.tool_calls) && m.tool_calls.some((c) => c.function?.name === "fm_branch_report"),
  );
  const ackMatch = seg
    .filter((m) => m.role === "tool")
    .map((m) => String(textOf(m.content)))
    .join("\n")
    .match(/bin\/fm-wake-drain\.sh --ack-through (\d+)( --recovery-generation (\S+))?/);
  const ackCmd = ackMatch
    ? `bin/fm-wake-drain.sh --ack-through ${ackMatch[1]}${ackMatch[2] || ""}`
    : `printf 'ack-unavailable\n'`;
  if (toolMsgs.length === 0) {
    return toolChunks(body.model, "bash", {
      command: "bin/fm-wake-drain.sh",
      // run_in_background false; timeout default
      description: "drain the supervision wake queue",
    });
  }
  if (toolMsgs.length === 1 && !hasReportCall) {
    return toolChunks(body.model, "fm_branch_report", {
      task,
      verdict: "routine",
      summary: "Live-validation branch handled the signal wake: drained the queue, verified task state, no captain action needed.",
      ...(wakeLine ? { wake: wakeLine } : {}),
      silent: false,
    });
  }
  if (toolMsgs.length === 2) {
    return toolChunks(body.model, "bash", {
      command: `${ackCmd} && printf 'branch-bash-tool-active ack=%s\n' "${ackMatch ? ackMatch[1] : "none"}" >> "$FM_HOME/state/branch-tool-activity.log"`,
      description: "acknowledge the handled wake",
    });
  }
  return textChunks(body.model, "Wake handled, outcome reported, queue acknowledged.");
};

// ---- main conversation derivation (per delivered wake) ----
const mainTurn = (body) => {
  const msgs = body.messages || [];
  const users = msgs.filter((m) => m.role === "user");
  const lastUser = String(textOf(users[users.length - 1]?.content));
  const seg = segmentAfter(msgs, "signal:");
  const segTools = seg.filter((m) => m.role === "tool");
  const hasArmCall = msgs.some(
    (m) => m.role === "assistant" && Array.isArray(m.tool_calls) && m.tool_calls.some((c) => c.function?.name === "fm_watch_arm_pi"),
  );
  const ackMatch = segTools
    .map((m) => String(textOf(m.content)))
    .join("\n")
    .match(/bin\/fm-wake-drain\.sh --ack-through (\d+)( --recovery-generation (\S+))?/);
  if (/fm_watch_arm_pi|arm supervision/i.test(lastUser) && !hasArmCall) {
    return toolChunks(body.model, "fm_watch_arm_pi", {});
  }
  if (/signal:|FIRSTMATE|wake/i.test(lastUser) && !/fm_watch_arm_pi|arm supervision/i.test(lastUser)) {
    if (segTools.length === 0) {
      return toolChunks(body.model, "bash", { command: "bin/fm-wake-drain.sh", description: "drain the wake queue" });
    }
    if (segTools.length === 1 && ackMatch) {
      return toolChunks(body.model, "bash", {
        command: `bin/fm-wake-drain.sh --ack-through ${ackMatch[1]}${ackMatch[2] || ""}`,
        description: "acknowledge the wake",
      });
    }
    return textChunks(body.model, "Handled.");
  }
  return textChunks(body.model, "ok");
};

const server = createServer((req, res) => {
  if (req.method !== "POST" || !req.url.includes("/chat/completions")) {
    log({ url: req.url, method: req.method, status: 404, note: "non-completions request" });
    res.writeHead(404).end();
    return;
  }
  let raw = "";
  req.on("data", (d) => (raw += d));
  req.on("end", () => {
    let body = {};
    try {
      body = JSON.parse(raw);
    } catch {
      log({ status: 400, note: "unparseable body" });
      res.writeHead(400).end();
      return;
    }
    const fields = Object.keys(body).sort();
    const forbidden = fields.filter((f) => FORBIDDEN_FIELDS.includes(f));
    const isBranch = body.model !== "lite";
    const auth = /^Bearer\s+\S+/.test(String(req.headers.authorization || ""));
    const m = mode();
    const base = {
      model: body.model,
      route: isBranch ? "branch" : "main",
      mode: m,
      fields,
      sent_prompt_cache_key: forbidden.length > 0,
      auth_header: auth,
      n_messages: (body.messages || []).length,
      n_tools: (body.tools || []).length,
    };
    if (forbidden.length > 0) {
      log({ ...base, status: 400, rejected_fields: forbidden, body: '{"type":"field_not_allowed"}' });
      res.writeHead(400, { "content-type": "application/json" });
      res.end(JSON.stringify({ type: "field_not_allowed", field: forbidden[0] }));
      return;
    }
    if (isBranch && m === "fail") {
      log({ ...base, status: 400, rejected_fields: ["(gateway incident mode: every branch request rejected)"], body: '{"type":"field_not_allowed"}' });
      res.writeHead(400, { "content-type": "application/json" });
      res.end(JSON.stringify({ type: "field_not_allowed", field: "gateway-incident-mode" }));
      return;
    }
    log({ ...base, status: 200 });
    try {
      sse(res, isBranch ? branchTurn(body) : mainTurn(body));
    } catch (error) {
      log({ ...base, status: 500, error: String(error) });
      res.writeHead(500).end();
    }
  });
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(JSON.stringify({ gateway: "listening", port: server.address().port }));
});
