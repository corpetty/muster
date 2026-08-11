// Drive a real two-party message exchange between two already-running
// logos-chat-ui instances and capture screenshots for the docs.
//
// A message exchange is inherently two-party, and the doc-test ui_test harness
// drives a single instance and cannot read a runtime value (an instance's
// address) out of one window to paste into another. This driver speaks the
// logos-qt-mcp inspector protocol directly to BOTH instances, so it can read
// Alice's address out and hand it to Bob, then screenshot each side of the
// conversation. Launch + teardown of the two apps is handled by run-exchange.sh;
// this script attaches to the two inspector ports it is given.
//
// Env:
//   ALICE_PORT / BOB_PORT   inspector ports (default 3768 / 3769)
//   OUT_DIR                  screenshot output dir (default ./images)
import net from "node:net";
import fs from "node:fs";

// ── inspector client: newline-delimited JSON over TCP, one socket per port ──
class Inspector {
  constructor(host, port) { this.host = host; this.port = port; this.socket = null; this.requestId = 0; this.pending = new Map(); this.buffer = ""; }
  async connect() {
    if (this.socket && !this.socket.destroyed) return;
    return new Promise((resolve, reject) => {
      const sock = net.createConnection({ host: this.host, port: this.port });
      sock.once("connect", () => { this.socket = sock; resolve(); });
      sock.once("error", (err) => reject(new Error(`connect ${this.port}: ${err.message}`)));
      sock.on("data", (c) => { this.buffer += c.toString("utf-8"); this._drain(); });
      sock.on("close", () => { this.socket = null; for (const [, p] of this.pending) { clearTimeout(p.timer); p.reject(new Error("connection closed")); } this.pending.clear(); });
      sock.on("error", () => {});
    });
  }
  _drain() { let i; while ((i = this.buffer.indexOf("\n")) !== -1) { const line = this.buffer.slice(0, i).trim(); this.buffer = this.buffer.slice(i + 1); if (!line) continue; try { const m = JSON.parse(line); const p = this.pending.get(String(m.id)); if (p) { clearTimeout(p.timer); this.pending.delete(String(m.id)); p.resolve(m); } } catch {} } }
  async send(command, params = {}) {
    await this.connect();
    const id = ++this.requestId;
    const payload = JSON.stringify({ id, command, params }) + "\n";
    return new Promise((resolve, reject) => { const timer = setTimeout(() => { this.pending.delete(String(id)); reject(new Error(`inspector timeout: ${command}`)); }, 30000); this.pending.set(String(id), { resolve, reject, timer }); this.socket.write(payload); });
  }
  disconnect() { if (this.socket) this.socket.destroy(); }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Evaluate a QML expression in ChatView's root scope (the ids store,
// conversationsPane and threadPane are all in scope there).
async function evalq(insp, expr) {
  const r = await insp.send("evaluate", { expression: expr });
  if (r.error) throw new Error(`eval(${expr}): ${r.error}`);
  return r.result;
}

async function waitFor(fn, { timeout = 180000, interval = 1000, what = "condition" } = {}) {
  const start = Date.now(); let last;
  while (Date.now() - start < timeout) {
    try { if (await fn()) return; } catch (e) { last = e; }
    await sleep(interval);
  }
  throw new Error(`timed out waiting for ${what}${last ? " (" + last.message + ")" : ""}`);
}

async function shoot(insp, outDir, name) {
  const r = await insp.send("screenshot", {});
  if (r.error || !r.image) throw new Error(`screenshot ${name}: ${r.error || "no image"}`);
  fs.writeFileSync(`${outDir}/${name}`, Buffer.from(r.image, "base64"));
  console.log(`  screenshot ${name} (${r.width}x${r.height})`);
}

// Select a conversation and wait for its thread to populate. The first
// get_messages can time out while chat_module is still busy with the network
// send, so re-select (deselect first — select is a no-op when already current)
// until the thread shows at least `minCount` messages.
async function loadThread(insp, convId, minCount, { timeout = 90000 } = {}) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    await evalq(insp, `store.backend.selectConversation("")`);
    await sleep(400);
    await evalq(insp, `store.backend.selectConversation(${JSON.stringify(convId)})`);
    const innerStart = Date.now();
    while (Date.now() - innerStart < 8000) {
      // threadReady as well as the count: the pane hides its rows until the
      // models report the selected conversation, and the screenshots that
      // follow must show the thread rather than its loading state.
      const shown = await evalq(insp, "threadPane.threadReady");
      const c = await evalq(insp, "threadPane.messageCount");
      if (shown === true && typeof c === "number" && c >= minCount) return c;
      await sleep(1000);
    }
  }
  throw new Error(`conversation thread did not reach ${minCount} message(s)`);
}

// Wait for the instance's own address. The backend reads it once the module
// comes online, so it surfaces on store.myAddress shortly after store.online.
async function getAddress(insp) {
  const start = Date.now();
  while (Date.now() - start < 25000) {
    const t = await evalq(insp, "store.myAddress");
    if (typeof t === "string" && t.length > 0) return t;
    await sleep(1000);
  }
  throw new Error("address was not produced");
}

const CONV_ID_ROLE = 257; // ConversationListModel::ConversationIdRole (Qt::UserRole + 1)
const PREVIEW_ROLE = 263; // ConversationListModel::PreviewRole

async function main() {
  const outDir = process.env.OUT_DIR || "./images";
  fs.mkdirSync(outDir, { recursive: true });
  const alice = new Inspector("127.0.0.1", parseInt(process.env.ALICE_PORT || "3768", 10));
  const bob = new Inspector("127.0.0.1", parseInt(process.env.BOB_PORT || "3769", 10));
  await alice.connect(); await bob.connect();
  console.log("connected to both inspectors");

  console.log("waiting for both instances to reach Online...");
  await waitFor(async () => (await evalq(alice, "store.online")) === true, { what: "alice Online" });
  await waitFor(async () => (await evalq(bob, "store.online")) === true, { what: "bob Online" });
  console.log("both Online");
  // A chat_module RPC issued the instant after Online can time out while the
  // module is still settling; let it quiesce before the first call.
  await sleep(3000);

  console.log("alice: read her address...");
  const address = await getAddress(alice);
  console.log(`alice address: ${address.length} chars`);
  await shoot(alice, outDir, "01-alice-address.png");

  console.log("bob: open a conversation with alice's address...");
  await evalq(bob, `store.backend.createConversation(${JSON.stringify(address)})`);
  await waitFor(async () => (await evalq(bob, "store.backend.currentConversationId")) !== "", { timeout: 30000, what: "bob conversation created" });

  // create_conversation sends only the cryptographic invite; wait until Alice
  // has joined (her conversation list shows it) before Bob's first message, so
  // the message reaches her subscribed thread rather than racing ahead of her
  // join (same ordering as chat-module's own two-instance doc-test).
  console.log("alice: wait for the incoming conversation...");
  await waitFor(async () => (await evalq(alice, "conversationsPane.count")) >= 1, { timeout: 150000, what: "alice joins conversation" });

  const BOB_MSG = "Hi Alice, it's Bob \u{1F44B}";
  console.log("bob: send the first message...");
  await evalq(bob, `store.backend.sendMessage(store.backend.currentConversationId, ${JSON.stringify(BOB_MSG)})`);
  await loadThread(bob, await evalq(bob, "store.backend.currentConversationId"), 1);
  console.log("bob: first message sent");
  // The sidebar preview reflects the latest message. Bob has one conversation,
  // so it is row 0; wait for the model replica to catch up to the sent content.
  await waitFor(
    async () => (await evalq(bob, `store.conversationModel.data(store.conversationModel.index(0,0), ${PREVIEW_ROLE})`)) === BOB_MSG,
    { timeout: 15000, what: "bob's sidebar preview to match the sent message" });
  console.log("bob: sidebar preview matches the sent message");
  await shoot(bob, outDir, "02-bob-sent.png");

  // Bob's message still has to cross the network here (the join wait above
  // only covered the invite), so budget the same 150s as the other
  // propagation waits.
  await loadThread(alice, await evalq(alice, `store.conversationModel.data(store.conversationModel.index(0,0), ${CONV_ID_ROLE})`), 1, { timeout: 150000 });
  console.log("alice: received Bob's message");
  await shoot(alice, outDir, "03-alice-received.png");

  const ALICE_REPLY = "Hi Bob, got it";
  console.log("alice: reply...");
  await evalq(alice, `store.backend.sendMessage(store.backend.currentConversationId, ${JSON.stringify(ALICE_REPLY)})`);
  await waitFor(async () => (await evalq(alice, "threadPane.messageCount")) >= 2, { timeout: 30000, what: "alice's reply in thread" });
  await shoot(alice, outDir, "04-alice-replied.png");

  console.log("bob: wait for the reply...");
  await waitFor(async () => (await evalq(bob, "threadPane.messageCount")) >= 2, { timeout: 150000, what: "bob receives reply" });
  console.log("bob: received the reply");
  await shoot(bob, outDir, "05-bob-roundtrip.png");

  alice.disconnect(); bob.disconnect();
  console.log("\nEXCHANGE COMPLETE: bidirectional round-trip verified; screenshots in " + outDir);
}

main().then(() => process.exit(0)).catch((e) => { console.error("\nFAILED:", e.message); process.exit(1); });
