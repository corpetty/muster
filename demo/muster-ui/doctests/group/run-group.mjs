// Drive a real three-party GROUP conversation across three logos-chat-ui
// instances and capture screenshots for the docs.
//
// A group chat spans more than two windows and grows by membership commits over
// the live network — something the single-instance doc-test ui_test driver can
// neither orchestrate nor read runtime addresses out of. This driver speaks the
// logos-qt-mcp inspector protocol to all three instances: Alice creates a group,
// invites Bob and Carol by address, waits for the roster to converge, then sends
// one message that fans out to both — exercising the members pane and the
// per-message sender attribution the group UI adds over a DM. Launch and
// teardown of the three apps is handled by run-group.sh; this script attaches to
// the three inspector ports it is given.
//
// Env:
//   ALICE_PORT / BOB_PORT / CAROL_PORT  inspector ports (default 3768/3769/3770)
//   OUT_DIR                              screenshot output dir (default ./images)
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
// conversationsPane and threadPane are all in scope there; store.memberModel is
// the roster).
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
async function loadThread(insp, convId, minCount, { timeout = 120000 } = {}) {
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

// Poll the roster until it lists at least `minCount` members. refreshMembers is
// idempotent — it re-reads list_group_members for the current group — so drive
// it from here rather than waiting on the membership-update event to land. It
// no-ops unless the group is the current conversation, so the caller must have
// selected it first.
async function waitForRoster(insp, minCount, { timeout = 150000, what = "roster" } = {}) {
  const start = Date.now(); let last = 0;
  while (Date.now() - start < timeout) {
    try {
      // memberCount is a backend property (reliably remoted), unlike the member
      // model's rowCount() over its QtRO replica; refreshMembers re-reads the
      // roster and updates it.
      await evalq(insp, "store.backend.refreshMembers()");
      last = await evalq(insp, "store.backend.memberCount");
      if (typeof last === "number" && last >= minCount) return last;
    } catch {}
    await sleep(2000);
  }
  throw new Error(`${what} did not reach ${minCount} members (last ${last})`);
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
const DISPLAY_NAME_ROLE = 258; // ConversationListModel::DisplayNameRole
// The group's shared name and description, set by the creator and carried to
// every joiner. The joiners' display name resolves to GROUP_NAME (nickname unset).
const GROUP_NAME = "Book Club";
const GROUP_DESC = "Weekly sci-fi picks";
// Must match doctests/chat-ui-group.test.yaml's wait_for text exactly:
// findByProperty matches the whole `text` property, not a substring.
const GROUP_MSG = "Hello team \u{1F44B}";

async function main() {
  const outDir = process.env.OUT_DIR || "./images";
  fs.mkdirSync(outDir, { recursive: true });
  const alice = new Inspector("127.0.0.1", parseInt(process.env.ALICE_PORT || "3768", 10));
  const bob   = new Inspector("127.0.0.1", parseInt(process.env.BOB_PORT   || "3769", 10));
  const carol = new Inspector("127.0.0.1", parseInt(process.env.CAROL_PORT || "3770", 10));
  await alice.connect(); await bob.connect(); await carol.connect();
  console.log("connected to all three inspectors");

  // Three full UI stacks (each with its own waku node) boot and peer on one host,
  // so allow more time to reach Online than the two-party exchange needs.
  console.log("waiting for all instances to reach Online...");
  await waitFor(async () => (await evalq(alice, "store.online")) === true, { timeout: 300000, what: "alice Online" });
  await waitFor(async () => (await evalq(bob,   "store.online")) === true, { timeout: 300000, what: "bob Online" });
  await waitFor(async () => (await evalq(carol, "store.online")) === true, { timeout: 300000, what: "carol Online" });
  console.log("all Online");
  // A chat_module RPC issued the instant after Online can time out while the
  // module is still settling; let it quiesce before the first call.
  await sleep(3000);

  console.log("bob/carol: read their addresses...");
  const bobAddr = await getAddress(bob);
  const carolAddr = await getAddress(carol);
  console.log(`bob address: ${bobAddr.length} chars, carol address: ${carolAddr.length} chars`);

  console.log("alice: create the group...");
  await evalq(alice, `store.backend.createGroupConversation(${JSON.stringify(GROUP_NAME)}, ${JSON.stringify(GROUP_DESC)})`);
  await waitFor(async () => (await evalq(alice, "store.backend.currentConversationId")) !== "", { timeout: 30000, what: "group created" });
  const groupId = await evalq(alice, "store.backend.currentConversationId");
  console.log(`group id: ${groupId}`);

  // Membership grows one commit at a time; wait for each invitee to actually
  // join (their conversation list shows the group) before the next invite, so
  // the second add starts from a settled group rather than racing the first.
  console.log("alice: invite bob...");
  await evalq(alice, `store.backend.addGroupMember(${JSON.stringify(groupId)}, ${JSON.stringify(bobAddr)})`);
  await waitFor(async () => (await evalq(bob, "conversationsPane.count")) >= 1, { timeout: 300000, what: "bob joins the group" });
  console.log("bob joined");

  console.log("alice: invite carol...");
  await evalq(alice, `store.backend.addGroupMember(${JSON.stringify(groupId)}, ${JSON.stringify(carolAddr)})`);
  await waitFor(async () => (await evalq(carol, "conversationsPane.count")) >= 1, { timeout: 300000, what: "carol joins the group" });
  console.log("carol joined");

  console.log("alice: wait for the roster to converge to three...");
  await waitForRoster(alice, 3, { what: "alice's roster" });
  await shoot(alice, outDir, "01-alice-group.png");

  console.log("alice: send the group message...");
  await evalq(alice, `store.backend.sendMessage(${JSON.stringify(groupId)}, ${JSON.stringify(GROUP_MSG)})`);
  await loadThread(alice, groupId, 1);
  console.log("alice: message sent");
  await shoot(alice, outDir, "02-alice-sent.png");

  // Carol is the last to join; her window is the group story end to end — the
  // creator's message received with a sender label, beside the three-member
  // roster. Load her thread first (leaves the group selected), then converge
  // her roster.
  console.log("carol: open the group and wait for alice's message...");
  const carolGroup = await evalq(carol, `store.conversationModel.data(store.conversationModel.index(0,0), ${CONV_ID_ROLE})`);
  // The shared name reached the joiner end to end: carol set no local nickname,
  // so her display name resolves to the group name Alice created it with.
  const carolName = await evalq(carol, `store.conversationModel.data(store.conversationModel.index(0,0), ${DISPLAY_NAME_ROLE})`);
  if (carolName !== GROUP_NAME) throw new Error(`carol should see the shared group name ${JSON.stringify(GROUP_NAME)}, got ${JSON.stringify(carolName)}`);
  console.log(`carol sees the group name: ${JSON.stringify(carolName)}`);
  await loadThread(carol, carolGroup, 1, { timeout: 300000 });
  await waitForRoster(carol, 3, { what: "carol's roster" });
  console.log("carol: received the group message");
  await shoot(carol, outDir, "03-carol-received.png");

  console.log("bob: confirm the message fanned out to him too...");
  const bobGroup = await evalq(bob, `store.conversationModel.data(store.conversationModel.index(0,0), ${CONV_ID_ROLE})`);
  await loadThread(bob, bobGroup, 1, { timeout: 300000 });
  await shoot(bob, outDir, "04-bob-received.png");

  alice.disconnect(); bob.disconnect(); carol.disconnect();
  console.log("\nGROUP COMPLETE: three-member group formed, message fanned out to both peers; screenshots in " + outDir);
}

main().then(() => process.exit(0)).catch((e) => { console.error("\nFAILED:", e.message); process.exit(1); });
