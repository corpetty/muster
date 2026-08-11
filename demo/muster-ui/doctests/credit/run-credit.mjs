// Does a shielded payment actually credit the recipient?
//
// The first two-peer payment (2026-08-11) debited the sender, rendered a
// receipt on both sides, and never moved the recipient's balance. The leading
// hypothesis is that a private account must be registered on-chain before it
// can be credited; `register_private_account` was added, and this script is
// what decides whether that was the cause.
//
// It drives both instances through the logos-qt-mcp inspector protocol — the
// same one doctests/exchange uses — because the question is about the wallet
// rather than about clicking: every step here is a `store` call the UI's own
// buttons make.
//
// The measurement that matters is the last one: the recipient's private
// balance before and after. A receipt is not evidence — the failing run
// produced one.
//
// Env:
//   ALICE_PORT / BOB_PORT   inspector ports (default 3768 / 3769)
//   AMOUNT                  whole LEZ to send (default 10)
//   PROVE_TIMEOUT_MS        how long to wait on the transfer (default 20 min)
import net from "node:net";

const AMOUNT = process.env.AMOUNT || "10";
const PROVE_TIMEOUT_MS = parseInt(process.env.PROVE_TIMEOUT_MS || "1200000", 10);
// MessageListModel::ContentRole — Qt::UserRole + 2. The roles are positional,
// so this tracks the enum in MessageListModel.h.
const CONTENT_ROLE = 258;
const CONV_ID_ROLE = 257; // ConversationListModel::ConversationIdRole

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
  async send(command, params = {}, timeoutMs = 60000) {
    await this.connect();
    const id = ++this.requestId;
    const payload = JSON.stringify({ id, command, params }) + "\n";
    return new Promise((resolve, reject) => { const timer = setTimeout(() => { this.pending.delete(String(id)); reject(new Error(`inspector timeout: ${command}`)); }, timeoutMs); this.pending.set(String(id), { resolve, reject, timer }); this.socket.write(payload); });
  }
  disconnect() { if (this.socket) this.socket.destroy(); }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function evalq(insp, expr) {
  const r = await insp.send("evaluate", { expression: expr });
  if (r.error) throw new Error(`eval(${expr}): ${r.error}`);
  return r.result;
}

async function waitFor(fn, { timeout = 180000, interval = 2000, what = "condition" } = {}) {
  const start = Date.now(); let last;
  while (Date.now() - start < timeout) {
    try { if (await fn()) return true; } catch (e) { last = e; }
    await sleep(interval);
  }
  throw new Error(`timed out waiting for ${what}${last ? " (" + last.message + ")" : ""}`);
}

// Balances are strings in the UI; compare them as numbers, and treat an empty
// or unparseable balance as unknown rather than as zero.
function num(v) {
  const n = parseInt(String(v ?? "").trim(), 10);
  return Number.isNaN(n) ? null : n;
}

async function walletState(insp) {
  return {
    ready: await evalq(insp, "store.walletReady"),
    busy: await evalq(insp, "store.walletBusy"),
    stage: await evalq(insp, "store.walletStage"),
    priv: await evalq(insp, "store.privateBalance"),
    pub: await evalq(insp, "store.publicBalance"),
    error: await evalq(insp, "store.walletError"),
  };
}

async function openWallet(insp, who) {
  console.log(`${who}: opening wallet...`);
  await evalq(insp, "store.openWallet()");
  await waitFor(async () => (await evalq(insp, "store.walletReady")) === true,
    { timeout: 600000, what: `${who} wallet open` });
  const s = await walletState(insp);
  console.log(`${who}: wallet open — private=${s.priv} public=${s.pub}`);
  if (s.error) console.log(`${who}: wallet error field: ${s.error}`);
  return s;
}

// The address-share card Bob put in the thread, as Alice's client sees it.
// Read from the message model rather than from Bob's wallet, because the keys
// that matter are the ones that actually crossed the conversation.
async function receiveKeysFromThread(insp) {
  const count = await evalq(insp, "store.messageModel.rowCount()");
  for (let i = 0; i < count; ++i) {
    const content = await evalq(insp,
      `store.messageModel.data(store.messageModel.index(${i},0), ${CONTENT_ROLE})`);
    if (typeof content !== "string" || content.charAt(0) !== "{") continue;
    try {
      const card = JSON.parse(content);
      if (card && card.muster && card.type === "address-share" && card.keys)
        return String(card.keys);
    } catch { /* not a card */ }
  }
  return null;
}

async function main() {
  const alice = new Inspector("127.0.0.1", parseInt(process.env.ALICE_PORT || "3768", 10));
  const bob = new Inspector("127.0.0.1", parseInt(process.env.BOB_PORT || "3769", 10));
  await alice.connect(); await bob.connect();
  console.log("connected to both inspectors\n");

  await waitFor(async () => (await evalq(alice, "store.online")) === true, { what: "alice Online" });
  await waitFor(async () => (await evalq(bob, "store.online")) === true, { what: "bob Online" });
  console.log("both Online");
  await sleep(3000);

  // ── wallets. Opening is what runs register_private_account, including the
  // repair path for an account minted before the fix existed.
  await openWallet(alice, "alice");
  const bobBefore = await openWallet(bob, "bob");

  // ── alice needs something to spend
  let alicePriv = num((await walletState(alice)).priv) ?? 0;
  if (alicePriv < parseInt(AMOUNT, 10)) {
    console.log(`\nalice: private balance ${alicePriv} < ${AMOUNT}; funding (PoW + shield, slow)...`);
    await evalq(alice, "store.fundWallet()");
    await waitFor(async () => {
      const s = await walletState(alice);
      if (s.error) console.log(`  alice stage=${s.stage} error=${s.error}`);
      return s.busy === false && (num(s.priv) ?? 0) >= parseInt(AMOUNT, 10);
    }, { timeout: 1800000, interval: 5000, what: "alice funded and shielded" });
    alicePriv = num((await walletState(alice)).priv) ?? 0;
  }
  console.log(`alice: private balance ${alicePriv}`);

  // ── a conversation, and bob's shielded address in it
  let convId = await evalq(bob, "store.backend.currentConversationId");
  if (!convId) {
    const addr = await evalq(alice, "store.myAddress");
    console.log("\nbob: opening a conversation with alice...");
    await evalq(bob, `store.backend.createConversation(${JSON.stringify(addr)})`);
    await waitFor(async () => (await evalq(bob, "store.backend.currentConversationId")) !== "",
      { timeout: 60000, what: "bob conversation created" });
    await waitFor(async () => (await evalq(alice, "actionsPane.count")) >= 1,
      { timeout: 180000, what: "alice joins the conversation" });
    convId = await evalq(bob, "store.backend.currentConversationId");
  }
  console.log(`conversation: ${convId}`);

  // Alice has to have *joined* before the card is sent, or it lands in a
  // thread she is not subscribed to and simply never arrives. Match on the
  // conversation id rather than taking row 0: a peer that has run before has
  // older conversations, and the newest-first sort is a proxy that lags.
  console.log("alice: waiting to join that conversation...");
  await waitFor(async () => {
    const n = await evalq(alice, "store.conversationModel.rowCount()");
    for (let i = 0; i < n; ++i) {
      const id = await evalq(alice,
        `store.conversationModel.data(store.conversationModel.index(${i},0), ${CONV_ID_ROLE})`);
      if (String(id) === String(convId)) return true;
    }
    return false;
  }, { timeout: 240000, interval: 3000, what: "alice to join the conversation" });

  await evalq(alice, `store.backend.selectConversation(${JSON.stringify(convId)})`);
  await sleep(1500);

  console.log("bob: sharing his shielded address...");
  await evalq(bob, "store.shareAddress()");

  const aliceConv = convId;

  let keys = null;
  await waitFor(async () => {
    await evalq(alice, `store.backend.selectConversation("")`);
    await sleep(300);
    await evalq(alice, `store.backend.selectConversation(${JSON.stringify(aliceConv)})`);
    await sleep(700);
    keys = await receiveKeysFromThread(alice);
    return keys !== null;
  }, { timeout: 240000, interval: 3000, what: "alice receives bob's address card" });
  console.log(`alice: got bob's shielded keys (${keys.length} chars)`);

  // ── the measurement
  await evalq(bob, "store.refreshBalances()");
  await waitFor(async () => (await evalq(bob, "store.walletBusy")) === false,
    { timeout: 600000, what: "bob's balance refresh" });
  const before = num((await walletState(bob)).priv);
  console.log(`\nBOB PRIVATE BALANCE BEFORE: ${before}`);

  console.log(`alice: paying ${AMOUNT} LEZ, shielded → shielded. The zone is proving; this took 6m41s last time.`);
  // The wallet must be idle first: sendPrivate declines while it is busy, and
  // "busy went false" is then true immediately — which reads as a transfer that
  // finished in zero seconds having never started. Wait for idle, start it,
  // and confirm it actually started before timing anything.
  await waitFor(async () => (await evalq(alice, "store.walletBusy")) === false,
    { timeout: 600000, interval: 5000, what: "alice's wallet to go idle before paying" });

  const t0 = Date.now();
  await evalq(alice, `store.sendPrivate(${JSON.stringify(keys)}, ${JSON.stringify(AMOUNT)})`);
  await waitFor(async () => (await evalq(alice, "store.walletBusy")) === true,
    { timeout: 60000, interval: 1000, what: "alice's transfer to start" });
  console.log("alice: transfer started (wallet is busy)");

  await waitFor(async () => {
    const s = await walletState(alice);
    if (s.error) throw new Error(`alice wallet error: ${s.error}`);
    return s.busy === false;
  }, { timeout: PROVE_TIMEOUT_MS, interval: 10000, what: "alice's transfer to finish" });
  const mins = ((Date.now() - t0) / 60000).toFixed(1);
  const aliceAfter = num((await walletState(alice)).priv);
  console.log(`alice: transfer finished in ${mins} min — her private balance ${alicePriv} -> ${aliceAfter}`);

  // Bob has to walk to the tip before he can see a note addressed to him, and
  // the failing run proved that syncing past the height is not sufficient on
  // its own — so refresh, wait, and refresh again before believing a zero.
  console.log("\nbob: syncing and re-reading his balance...");
  let after = null;
  for (let attempt = 1; attempt <= 6; ++attempt) {
    await evalq(bob, "store.refreshBalances()");
    await waitFor(async () => (await evalq(bob, "store.walletBusy")) === false,
      { timeout: 600000, what: "bob's balance refresh" });
    after = num((await walletState(bob)).priv);
    console.log(`  attempt ${attempt}: bob private = ${after}`);
    if (after !== null && before !== null && after > before) break;
    await sleep(20000);
  }

  console.log(`\n${"=".repeat(60)}`);
  console.log(`BOB PRIVATE BALANCE: ${before} -> ${after}`);
  if (before !== null && after !== null && after > before) {
    console.log(`RESULT: CREDITED (+${after - before}). register_private_account is confirmed as the fix.`);
  } else {
    console.log("RESULT: NOT CREDITED. The registration hypothesis is wrong, or incomplete.");
    console.log("Next suspects, per the note in ChatBackendWallet.cpp: note detection needing a");
    console.log("scan this code does not perform, or get_private_account_keys not returning what");
    console.log("transfer_private actually credits.");
  }
  console.log(`${"=".repeat(60)}`);

  alice.disconnect(); bob.disconnect();
  process.exit(before !== null && after !== null && after > before ? 0 : 1);
}

main().catch((e) => { console.error("\nFAILED:", e.message); process.exit(2); });
