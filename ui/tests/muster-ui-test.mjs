#!/usr/bin/env node
// Muster UI acceptance test (P4). Drives muster-ui in a logos-basecamp host via
// logos-qt-mcp and asserts the real lifecycle surfaces:
//   1. the view instantiates and renders (the exo-c6a blocker; ADR-013),
//   2. muster_module.health() marshals back to "ok",
//   3. propose → the module re-derives the EIP-712 safeTxHash and the
//      re-materialization strip shows it (F-4 / invariant 1, the real check).
// A screenshot is written to MUSTER_SHOT (default ./muster-ui.png).
//
// Usage:
//   LOGOS_QT_MCP=<qt-mcp> node muster-ui-test.mjs --ci <basecamp-app-binary> [--verbose]
//
// The app-under-test is a logos-basecamp dev build with muster_module + muster_ui
// baked in — see README.md in this directory for how to produce it. This runs
// offscreen (QT_QPA_PLATFORM=offscreen); no display needed.

import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { writeFileSync } from "node:fs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const qtMcpRoot = process.env.LOGOS_QT_MCP || resolve(__dirname, "result-mcp");
const { test, run } = await import(resolve(qtMcpRoot, "test-framework/framework.mjs"));

// The sidebar launcher shows the display name ("Muster"); older hosts keyed the
// module name. Try both so the harness is host-version tolerant.
async function openMuster(app) {
  for (const name of ["Muster", "muster_ui"]) {
    try { await app.click(name); return; } catch { /* try the next spelling */ }
  }
  throw new Error("no muster sidebar launcher (tried Muster / muster_ui)");
}

async function setField(app, objectName, value) {
  const r = await app.inspector.send("findByProperty", { property: "objectName", value: objectName });
  const id = r.matches?.[0]?.id;
  if (!id) throw new Error(`propose field "${objectName}" not found`);
  await app.inspector.send("setProperty", { objectId: id, property: "text", value: String(value) });
}

// 1) RENDER — the decisive ADR-013 check: the coherent-built view instantiates.
test("muster_ui: the view instantiates and renders", async (app) => {
  await openMuster(app);
  await app.waitFor(
    async () => { await app.expectTexts(["Muster", "Propose a transfer"]); },
    { timeout: 15000, interval: 500, description: "muster_ui view to render" }
  );
});

// 2) BACKEND — muster_module.health() marshals to "ok" over the coherent chain.
test("muster_ui: muster_module.health() marshals to ok", async (app) => {
  await openMuster(app);
  await app.waitFor(
    async () => { await app.expectTexts(["module.health() → ok"]); },
    { timeout: 15000, interval: 500, description: "health() -> ok" }
  );
});

// 3) PROPOSE — the module re-derives the safeTxHash from the effect and the
//    re-materialization strip shows it. This is the first real F-4 check in the
//    UI (not the prototype's simulated hashes). findByProperty is exact-match, so
//    assert on the strip's row label ("re-derived") and the status rail
//    ("proposed") — both render only once an intent exists.
test("muster_ui: propose drives the real re-materialization strip", async (app) => {
  await openMuster(app);
  await app.waitFor(
    async () => { await app.expectTexts(["Propose a transfer"]); },
    { timeout: 15000, interval: 500, description: "composer ready" }
  );
  await setField(app, "proposeTo", "0x1111111111111111111111111111111111111111");
  await setField(app, "proposeValue", "1000");
  await setField(app, "proposeNonce", "0");
  const btn = await app.inspector.send("findByProperty", { property: "objectName", value: "proposeButton" });
  const btnId = btn.matches?.[0]?.id;
  if (!btnId) throw new Error("proposeButton not found");
  await app.inspector.send("callMethod", { objectId: btnId, method: "clicked" });
  await app.waitFor(
    async () => { await app.expectTexts(["re-derived", "proposed"]); },
    { timeout: 15000, interval: 500, description: "re-materialization strip" }
  );
  console.log("[muster] PROPOSE OK — module re-derived the safeTxHash; strip + status rail rendered");

  // Best-effort visual artifact.
  try {
    const shot = await app.screenshot();
    const b64 = shot?.data || shot?.image || shot?.png || (typeof shot === "string" ? shot : null);
    if (b64) {
      const out = process.env.MUSTER_SHOT || resolve(process.cwd(), "muster-ui.png");
      writeFileSync(out, Buffer.from(String(b64).replace(/^data:image\/png;base64,/, ""), "base64"));
      console.log(`[muster] screenshot → ${out}`);
    }
  } catch (e) { console.log(`[muster] screenshot skipped: ${e.message}`); }
});

run();
