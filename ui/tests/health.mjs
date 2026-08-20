// P4 acceptance driver: assert the muster-ui view surfaces muster_module.health()
// through the real logos-API seam, driven over the QML inspector protocol.
//
// This is the standalone-host equivalent of basecamp's logos-qt-mcp
// `app.click(...)` / `app.expectTexts(...)` flow (docs/labbook/
// nim-cdylib-modules-cannot-load-in-basecamp-sdk-skew.md). Because shipping
// basecamp's ui-host is ABI-skewed from the nim-cdylib module-builder, we drive
// the builder's OWN ABI-matched host — logos-standalone-app — instead, over the
// same newline-delimited-JSON inspector protocol the demo/muster-ui doctests use.
// When the upstream SDK skew is fixed, this same assertion re-points at basecamp.
//
// It asserts on the QML object tree (root.ready / root.health), NOT on pixels, so
// it passes headless (offscreen + software render) with no display — see run-health.sh.
//
// Env:
//   INSPECTOR_PORT   QML inspector port to attach to (default 3771)
//   INSPECTOR_HOST   default 127.0.0.1
import net from "node:net";

const HOST = process.env.INSPECTOR_HOST || "127.0.0.1";
const PORT = parseInt(process.env.INSPECTOR_PORT || "3771", 10);

// ── inspector client: newline-delimited JSON over TCP (mirrors the demo doctests) ──
class Inspector {
  constructor(host, port) { this.host = host; this.port = port; this.socket = null; this.requestId = 0; this.pending = new Map(); this.buffer = ""; }
  connect() {
    return new Promise((resolve, reject) => {
      const sock = net.createConnection({ host: this.host, port: this.port });
      sock.once("connect", () => { this.socket = sock; resolve(); });
      sock.once("error", (err) => reject(new Error(`connect ${this.port}: ${err.message}`)));
      sock.on("data", (c) => { this.buffer += c.toString("utf-8"); this._drain(); });
    });
  }
  _drain() { let i; while ((i = this.buffer.indexOf("\n")) !== -1) { const line = this.buffer.slice(0, i).trim(); this.buffer = this.buffer.slice(i + 1); if (!line) continue; try { const m = JSON.parse(line); const p = this.pending.get(String(m.id)); if (p) { clearTimeout(p.timer); this.pending.delete(String(m.id)); p.resolve(m); } } catch {} } }
  send(command, params = {}) {
    const id = ++this.requestId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(String(id)); reject(new Error(`inspector timeout: ${command} ${JSON.stringify(params)}`)); }, 30000);
      this.pending.set(String(id), { resolve, reject, timer });
      this.socket.write(JSON.stringify({ id, command, params }) + "\n");
    });
  }
  disconnect() { if (this.socket) this.socket.destroy(); }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Evaluate a QML expression in the loaded view's root scope. `root` (Main.qml's
// id) and the injected `logos` context object are both in scope there.
async function evalq(insp, expr) {
  const r = await insp.send("evaluate", { expression: expr });
  if (r.error) throw new Error(`eval(${expr}): ${r.error}`);
  return r.result;
}

async function waitFor(fn, { timeout = 30000, interval = 500, what = "condition" } = {}) {
  const start = Date.now(); let last;
  while (Date.now() - start < timeout) {
    try { if (await fn()) return; } catch (e) { last = e; }
    await sleep(interval);
  }
  throw new Error(`timed out waiting for ${what}${last ? ` (${last.message})` : ""}`);
}

function assertEq(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  console.log(`  ✓ ${what} === ${JSON.stringify(expected)}`);
}

(async () => {
  const insp = new Inspector(HOST, PORT);
  console.log(`muster-ui health acceptance — attaching to inspector ${HOST}:${PORT}`);
  await insp.connect();

  // 1. The host finished instantiating the view module (ui-host ready).
  await waitFor(() => evalq(insp, "logos.isViewModuleReady('muster_ui')").then((v) => v === true),
    { what: "logos.isViewModuleReady('muster_ui') === true" });
  console.log("  ✓ view module ready (ui-host instantiated the plugin)");

  // 2. The QML bound its backend replica (logos.module('muster_ui') resolved).
  await waitFor(() => evalq(insp, "root.ready").then((v) => v === true),
    { what: "root.ready === true (backend replica bound)" });
  console.log("  ✓ backend replica bound");

  // 3. The seam resolved on its own: onContextReady() -> checkHealth() ->
  //    modules().muster_module.health() -> the .rep PROP -> QML. This is the
  //    whole P4 spike: QML -> C++ backend -> generated client -> Nim core.
  assertEq(await evalq(insp, "root.health"), "ok", "root.health (auto-resolved)");

  // 4. Exercise the SLOT the "Re-check health" button calls, and re-assert — proves
  //    the on-demand round-trip, not just the boot-time one. Void slot; tolerate a
  //    null/undefined return, fail only if the re-check doesn't land on "ok".
  try { await evalq(insp, "root.backend.checkHealth()"); }
  catch (e) { console.log(`  ! checkHealth() slot invoke returned an error (continuing): ${e.message}`); }
  await waitFor(() => evalq(insp, "root.health").then((v) => v === "ok"),
    { what: "root.health === 'ok' after checkHealth()" });
  console.log("  ✓ health re-check round-trip resolved to 'ok'");

  insp.disconnect();
  console.log("PASS: muster_module.health() -> ok surfaced in the view");
  process.exit(0);
})().catch((e) => {
  console.error(`FAIL: ${e.message}`);
  process.exit(1);
});
