// Select the group conversation in an already-running logos-chat-ui instance,
// over the logos-qt-mcp inspector protocol, then exit leaving it shown with its
// roster loaded.
//
// Used by run-group-show.sh: after the three-party group flow completes, Carol's
// live window is about to be exposed to the doc-test's capture step. This picks
// the conversation, opens its thread, and refreshes the roster so the screenshot
// shows the received message beside the members pane — without needing to know
// the conversation id (which is generated at runtime).
//
// Env:
//   SHOW_PORT   inspector port to attach to (default 3768)
import net from "node:net";

// Newline-delimited JSON over TCP, one request/response per id.
class Inspector {
  constructor(host, port) { this.host = host; this.port = port; this.socket = null; this.requestId = 0; this.pending = new Map(); this.buffer = ""; }
  connect() {
    return new Promise((resolve, reject) => {
      const sock = net.createConnection({ host: this.host, port: this.port });
      sock.once("connect", () => { this.socket = sock; resolve(); });
      sock.once("error", (err) => reject(new Error(`connect ${this.port}: ${err.message}`)));
      sock.on("data", (c) => { this.buffer += c.toString("utf-8"); this._drain(); });
      sock.on("error", () => {});
    });
  }
  _drain() { let i; while ((i = this.buffer.indexOf("\n")) !== -1) { const line = this.buffer.slice(0, i).trim(); this.buffer = this.buffer.slice(i + 1); if (!line) continue; try { const m = JSON.parse(line); const p = this.pending.get(String(m.id)); if (p) { clearTimeout(p.timer); this.pending.delete(String(m.id)); p.resolve(m); } } catch {} } }
  send(command, params = {}) {
    const id = ++this.requestId;
    return new Promise((resolve, reject) => { const timer = setTimeout(() => { this.pending.delete(String(id)); reject(new Error(`inspector timeout: ${command}`)); }, 30000); this.pending.set(String(id), { resolve, reject, timer }); this.socket.write(JSON.stringify({ id, command, params }) + "\n"); });
  }
  disconnect() { if (this.socket) this.socket.destroy(); }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Evaluate a QML expression in ChatView's root scope (ids store, conversationsPane, threadPane).
async function evalq(insp, expr) {
  const r = await insp.send("evaluate", { expression: expr });
  if (r.error) throw new Error(`eval(${expr}): ${r.error}`);
  return r.result;
}

async function waitFor(insp, expr, pred, { timeout = 90000, interval = 1000, what = "condition" } = {}) {
  const start = Date.now(); let last;
  while (Date.now() - start < timeout) {
    try { const v = await evalq(insp, expr); if (pred(v)) return v; } catch (e) { last = e; }
    await sleep(interval);
  }
  throw new Error(`timed out waiting for ${what}${last ? " (" + last.message + ")" : ""}`);
}

const CONV_ID_ROLE = 257; // ConversationListModel::ConversationIdRole (Qt::UserRole + 1)

async function main() {
  const insp = new Inspector("127.0.0.1", parseInt(process.env.SHOW_PORT || "3768", 10));
  await insp.connect();

  await waitFor(insp, "conversationsPane.count", (c) => typeof c === "number" && c >= 1,
    { timeout: 90000, what: "conversation to be listed" });

  const convId = await evalq(insp, `store.conversationModel.data(store.conversationModel.index(0,0), ${CONV_ID_ROLE})`);
  await evalq(insp, `store.backend.selectConversation(${JSON.stringify(convId)})`);

  // Wait for the thread to be rendered, not merely for the model to hold rows:
  // the pane keeps its rows hidden until the models report the selected
  // conversation, so the held window would otherwise be captured mid-load.
  await waitFor(insp, "threadPane.threadReady && threadPane.messageCount >= 1", (v) => v === true,
    { timeout: 60000, what: "conversation thread to load" });
  // Refresh the roster so the members pane is populated in the screenshot.
  // memberCount is a backend property, reliable unlike the model replica's rowCount.
  await evalq(insp, "store.backend.refreshMembers()");
  await waitFor(insp, "store.backend.memberCount", (c) => typeof c === "number" && c >= 1,
    { timeout: 30000, what: "roster to load" });

  console.log(`selected group ${convId}; thread and roster shown`);
  insp.disconnect();
}

main().then(() => process.exit(0)).catch((e) => { console.error("select-group FAILED:", e.message); process.exit(1); });
