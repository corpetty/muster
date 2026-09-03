#!/usr/bin/env node
// Muster UI acceptance test (P4). Drives muster-ui in a logos-basecamp host via
// logos-qt-mcp and asserts the real lifecycle surfaces:
//   1. the view instantiates and renders (the exo-c6a blocker; ADR-013),
//   2. muster_module.health() marshals back to "ok",
//   3. propose → the module re-derives the EIP-712 safeTxHash and the
//      re-materialization strip shows it (F-4 / invariant 1, the real check).
//   4. the room surface renders and navigation reaches it (Room.qml on-display).
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
  if (!id) throw new Error(`field "${objectName}" not found`);
  await app.inspector.send("setProperty", { objectId: id, property: "text", value: String(value) });
}

async function clickButton(app, objectName) {
  const r = await app.inspector.send("findByProperty", { property: "objectName", value: objectName });
  const id = r.matches?.[0]?.id;
  if (!id) throw new Error(`button "${objectName}" not found`);
  await app.inspector.send("callMethod", { objectId: id, method: "clicked" });
}

async function propertyOf(app, objectName, expr) {
  const r = await app.inspector.send("findByProperty", { property: "objectName", value: objectName });
  const id = r.matches?.[0]?.id;
  if (!id) throw new Error(`element "${objectName}" not found`);
  return (await app.inspector.send("evaluate", { objectId: id, expression: expr })).result;
}

// Pre-signed anvil-owner signatures over the safeTxHash the module re-derives for
// the effect {to: 0x1111…1111, value: 1000, nonce: 0} against the baked Safe
// config (chain 31337; owners = anvil accounts 0/1/2; threshold 2). Each is a raw
// ECDSA signature over the 32-byte safeTxHash (what a Safe owner signs). Regenerate
// if the effect or Safe config changes:
//   cast wallet sign --no-hash --private-key <anvil key N> 0x<intent txhash>
const OWNER_SIGS = [
  "0x00278ad6c27d00993883a10909200661d6559d4eea8ca3c9ee3367e8761ba7056fe11cb9a6e87ede5aef673a0f075b220a3c6d37842743c91d9868d834edffcd1b", // anvil owner 0 (0xf39F…2266)
  "0x7089eabcc8f8d1ff49a4b420d59f9b51f78ce7b498a5d4d17f1e07c0915231ca6443249c38693bbe3f1c12fc87e3a909c7c1e6ad8401d3d03c0b1fb751aa9d241b", // anvil owner 1 (0x7099…79C8)
];
// A signature over the same safeTxHash from anvil account 3 (0x90F7…b906), which
// is NOT in the owner set — the module must refuse to count it.
const NON_OWNER_SIG =
  "0x434ffc353ac48d485e94d1a03d03fdd8279204e9de49e73e0ab3023b392ae2297c3de7242a294bfdc689544d2dd256b7b447659bda23624cb8ef8b247875773f1c";

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
  await clickButton(app, "proposeButton");
  await app.waitFor(
    async () => { await app.expectTexts(["re-derived", "proposed"]); },
    { timeout: 15000, interval: 500, description: "re-materialization strip" }
  );
  console.log("[muster] PROPOSE OK — module re-derived the safeTxHash; strip + status rail rendered");

});

// 4) LIFECYCLE — collect owner signatures until the driver reports the threshold
//    met. Each signature is verified by the module (recovers to a configured
//    owner) before it counts; the status rail advances proposed → collecting →
//    executable. This exercises the real approve/status surface end to end.
test("muster_ui: collecting owner signatures advances to executable", async (app) => {
  await openMuster(app);
  await app.waitFor(
    async () => { await app.expectTexts(["Propose a transfer"]); },
    { timeout: 15000, interval: 500, description: "composer ready" }
  );
  await setField(app, "proposeTo", "0x1111111111111111111111111111111111111111");
  await setField(app, "proposeValue", "1000");
  await setField(app, "proposeNonce", "0");
  await clickButton(app, "proposeButton");
  await app.waitFor(
    async () => { await app.expectTexts(["re-derived"]); },
    { timeout: 15000, interval: 500, description: "intent proposed" }
  );

  // Collect each owner signature. The last one crosses the threshold, at which
  // point the "executable" notice becomes visible (the approve affordance hides).
  for (const sig of OWNER_SIGS) {
    await setField(app, "approveSig", sig);
    await clickButton(app, "approveButton");
  }
  await app.waitFor(
    async () => {
      if ((await propertyOf(app, "executableNotice", "visible")) !== true)
        throw new Error("intent not yet executable");
    },
    { timeout: 15000, interval: 500, description: "threshold met → executable" }
  );
  console.log("[muster] LIFECYCLE OK — 2 owner signatures collected → executable");
  await grab(app, "executable");
});

// 4b) REJECT + RESET — a non-owner signature must not count (the error banner
//     shows the module's own reason and the intent does not advance), and reset
//     clears the intent for a fresh walkthrough. Off-chain; no anvil needed.
test("muster_ui: a non-owner signature is rejected, then reset clears the intent", async (app) => {
  await openMuster(app);
  await app.waitFor(
    async () => { await app.expectTexts(["Propose a transfer"]); },
    { timeout: 15000, interval: 500, description: "composer ready" }
  );
  await setField(app, "proposeTo", "0x1111111111111111111111111111111111111111");
  await setField(app, "proposeValue", "1000");
  await setField(app, "proposeNonce", "0");
  await clickButton(app, "proposeButton");
  await app.waitFor(
    async () => { await app.expectTexts(["re-derived"]); },
    { timeout: 15000, interval: 500, description: "intent proposed" }
  );

  await setField(app, "approveSig", NON_OWNER_SIG);
  await clickButton(app, "approveButton");
  await app.waitFor(
    async () => {
      if ((await propertyOf(app, "errorBanner", "visible")) !== true)
        throw new Error("no error shown for the non-owner signature");
    },
    { timeout: 15000, interval: 500, description: "error banner" }
  );
  if ((await propertyOf(app, "executableNotice", "visible")) === true)
    throw new Error("a non-owner signature wrongly advanced the intent to executable");
  console.log("[muster] REJECT OK — non-owner signature not counted; error shown, intent held");

  await clickButton(app, "errorResetButton");
  await app.waitFor(
    async () => {
      if ((await propertyOf(app, "intentCard", "visible")) !== false)
        throw new Error("reset did not clear the intent");
    },
    { timeout: 10000, interval: 500, description: "reset → fresh composer" }
  );
  console.log("[muster] RESET OK — intent cleared for a new proposal");
});

// 4c) WALKTHROUGH — the ADR-012 claims registry rendered as the lifecycle
//     legend. Toggling it on shows the six steps with their protects/leak/gap
//     claims; the data is ClaimsRegistry.qml (generated from
//     contracts/claims/registry.json, drift-checked in CI). Off-chain; no anvil.
test("muster_ui: the walkthrough renders the claims registry", async (app) => {
  await openMuster(app);
  await app.waitFor(
    async () => { await app.expectTexts(["Muster"]); },
    { timeout: 15000, interval: 500, description: "muster_ui view" }
  );
  await clickButton(app, "walkthroughToggle");
  await app.waitFor(
    async () => {
      await app.expectTexts([
        "The transaction lifecycle", // the walkthrough header
        "Open the room",             // first step title
        "Settle and record",         // last step title
        "PROTECTS",                  // a protects badge
        "GAP",                       // a gap badge
      ]);
    },
    { timeout: 15000, interval: 500, description: "walkthrough legend rendered" }
  );
  const r = await app.inspector.send("findByProperty", { property: "objectName", value: "claimCard" });
  if (!(r.matches?.length > 0))
    throw new Error("no claim cards rendered in the walkthrough");
  console.log(`[muster] WALKTHROUGH OK — ${r.matches.length} claim cards across the six steps`);
  await grab(app, "walkthrough");
});

async function grab(app, suffix) {
  await new Promise((r) => setTimeout(r, 1500)); // let the render thread catch up
  try {
    const shot = await app.screenshot();
    const b64 = shot?.data || shot?.image || shot?.png || (typeof shot === "string" ? shot : null);
    if (b64) {
      const base = process.env.MUSTER_SHOT || resolve(process.cwd(), "muster-ui.png");
      const out = suffix ? base.replace(/\.png$/, `-${suffix}.png`) : base;
      writeFileSync(out, Buffer.from(String(b64).replace(/^data:image\/png;base64,/, ""), "base64"));
      console.log(`[muster] screenshot → ${out}`);
    }
  } catch (e) { console.log(`[muster] screenshot skipped: ${e.message}`); }
}

// 5) SUBMIT — an executable intent is sent on-chain: the module assembles the Safe
//    execTransaction from the collected signatures, submits it through the user's
//    RPC, and reads finality from the receipt (R-8). REQUIRES anvil running with the
//    MiniSafe deployed at the module's configured address (0x5FbDB…) and funded —
//    see README.md. The effect's nonce (0) must match the Safe's on-chain nonce, so
//    run this against a fresh Safe (this is the only test that moves it on-chain).
test("muster_ui: submit executes the intent on-chain and reaches final", async (app) => {
  await openMuster(app);
  await app.waitFor(
    async () => { await app.expectTexts(["Propose a transfer"]); },
    { timeout: 15000, interval: 500, description: "composer ready" }
  );
  await setField(app, "proposeTo", "0x1111111111111111111111111111111111111111");
  await setField(app, "proposeValue", "1000");
  await setField(app, "proposeNonce", "0");
  await clickButton(app, "proposeButton");
  await app.waitFor(
    async () => { await app.expectTexts(["re-derived"]); },
    { timeout: 15000, interval: 500, description: "intent proposed" }
  );
  for (const sig of OWNER_SIGS) {
    await setField(app, "approveSig", sig);
    await clickButton(app, "approveButton");
  }
  await app.waitFor(
    async () => {
      if ((await propertyOf(app, "executableNotice", "visible")) !== true)
        throw new Error("intent not yet executable");
    },
    { timeout: 15000, interval: 500, description: "executable" }
  );

  await clickButton(app, "submitButton");
  await app.waitFor(
    async () => {
      if ((await propertyOf(app, "finalNotice", "visible")) !== true)
        throw new Error("intent not yet final (is anvil up with the Safe deployed?)");
    },
    { timeout: 30000, interval: 1000, description: "on-chain execution → final" }
  );
  console.log("[muster] SUBMIT OK — execTransaction landed on-chain; intent reached final");
  await grab(app, "final");
});

// 4d) ROOM — the conversation surface renders and navigation reaches it. Clicking
//     the Room nav switches surfaces (the room becomes visible, home hides) and the
//     room draws its join affordance (topic field + Join). This is the on-display
//     gate for Room.qml + MusterCard.qml under ADR-011 (nix build does not evaluate
//     QML, so a bad type name would blank the view — caught here, on a real host).
//
//     It stops at render on purpose: joining drives coordinate_join →
//     DeliveryTransport, which needs delivery_module loaded. muster_module declares
//     no dependency on it and this bake does not carry it, so the functional
//     propose → card → contribute loop belongs with the live delivery node (the
//     documented cross-host item), not here. The fold those cards render from is
//     covered headless (module/tests/coordination_surface_test.nim step 6).
//     Off-chain; no anvil needed.
test("muster_ui: navigating to the room renders its join affordance", async (app) => {
  await openMuster(app);
  await app.waitFor(
    async () => { await app.expectTexts(["Muster"]); },
    { timeout: 15000, interval: 500, description: "muster_ui view" }
  );

  await clickButton(app, "roomToggle");

  // Navigation actually switched surfaces — not just that the text exists in the
  // (always-instantiated) tree. The room is shown; home is hidden.
  await app.waitFor(
    async () => {
      if ((await propertyOf(app, "roomSurface", "visible")) !== true)
        throw new Error("room surface not visible after roomToggle");
      if ((await propertyOf(app, "homeSurface", "visible")) !== false)
        throw new Error("home surface still visible after roomToggle");
    },
    { timeout: 15000, interval: 500, description: "room surface shown" }
  );

  // The join affordance rendered — proves Room.qml's Logos.Controls instantiated.
  for (const name of ["roomTopicField", "joinRoomButton"]) {
    const r = await app.inspector.send("findByProperty", { property: "objectName", value: name });
    if (!(r.matches?.length > 0))
      throw new Error(`room element "${name}" not found — Room.qml did not render`);
  }
  await app.expectTexts(["Join a room"]);
  console.log("[muster] ROOM OK — navigated to the room; join affordance rendered");
  await grab(app, "room");
});

// 9) ROOM VERIFY BOX — the contracting-stage on-display proof. Join a room, propose
//    a Safe transfer in-room, and assert the proposal card's verify box renders the
//    client-RE-DERIVED safeTxHash (shown → re-derived → domain) with the "exact bytes
//    you'd sign" affirmation. This is the render that moves the Contracting stage from
//    ◑ to ● — invariant 1 / F-4 visible in the shipping Room card, not only the
//    Account/propose strip (test 3). Needs delivery_module in the bake so
//    coordinate_join resolves; a single instance folds locally (publish() records to
//    the log before broadcasting), so the card renders offscreen with no peer.
//    Off-chain; no anvil needed.
test("muster_ui: an in-room proposal renders the re-derived verify box", async (app) => {
  await openMuster(app);
  await app.waitFor(
    async () => { await app.expectTexts(["Muster"]); },
    { timeout: 15000, interval: 500, description: "muster_ui view" }
  );

  // Navigate to the room and join a local topic. A single instance boots an
  // isolated delivery node and folds its own proposals locally.
  await clickButton(app, "roomToggle");
  await setField(app, "roomTopicField", "muster.contracting.verify");
  await clickButton(app, "joinRoomButton");
  await app.waitFor(
    async () => {
      if ((await propertyOf(app, "roomMembersLabel", "visible")) !== true)
        throw new Error("room not joined (is delivery_module in the bake?)");
    },
    { timeout: 20000, interval: 500, description: "room joined" }
  );

  // Compose a Safe payment in-room: open the composer, pick payment + Safe (so the
  // driver re-derives an EIP-712 safeTxHash), fill the effect, propose.
  await clickButton(app, "roomProposeButton");
  await clickButton(app, "roomKindPayment");
  await clickButton(app, "roomPolicySafe");
  await setField(app, "roomProposeTo", "0x1111111111111111111111111111111111111111");
  await setField(app, "roomProposeValue", "1000");
  await clickButton(app, "roomProposeSubmit");

  // A proposal card renders from the verified fold. Open its verify box (the card
  // owns the toggle) on every rendered card — the intent card is the one with a hash.
  await app.waitFor(
    async () => {
      const r = await app.inspector.send("findByProperty", { property: "objectName", value: "musterCard" });
      if (!(r.matches?.length > 0)) throw new Error("no proposal card rendered");
      for (const m of r.matches)
        await app.inspector.send("setProperty", { objectId: m.id, property: "verifyOpen", value: true });
    },
    { timeout: 20000, interval: 500, description: "proposal card in the thread" }
  );

  // The verify box is on-display and carries the re-derivation affirmation.
  await app.waitFor(
    async () => {
      if ((await propertyOf(app, "verifyBox", "visible")) !== true)
        throw new Error("verify box not visible (card has no txhash?)");
    },
    { timeout: 15000, interval: 500, description: "verify box on-display" }
  );
  await app.expectTexts(["✓ your client re-derived this — the exact bytes you'd sign"]);

  // The decisive assertion: the box shows a real re-derived safeTxHash (32 bytes)
  // bound to a non-empty domain (chain + Safe). Polled — the Repeater rows populate
  // a tick after verifyOpen flips.
  let rederived = "", domain = "";
  await app.waitFor(
    async () => {
      rederived = String((await propertyOf(app, "verifyVal_re-derived", "text")) || "");
      domain    = String((await propertyOf(app, "verifyVal_domain", "text")) || "");
      if (!/^0x[0-9a-fA-F]{64}$/.test(rederived))
        throw new Error(`re-derived not yet a 32-byte safeTxHash: "${rederived}"`);
      if (domain.length === 0)
        throw new Error("domain row empty — signature not shown bound to (chain, Safe)");
    },
    { timeout: 15000, interval: 500, description: "verify rows populated" }
  );
  console.log(`[muster] VERIFY BOX OK — re-derived ${rederived} bound to ${domain}`);
  await grab(app, "verify");
});

run();
