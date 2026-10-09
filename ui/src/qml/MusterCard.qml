import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// A typed card that rode inside a room message as JSON, rendered where it was
// agreed. Five kinds: the ask for an address, the address that answers it, a
// proposal the room decides on, a bare approval, and the receipt for the
// payment that followed. This component is pure render — data comes in through
// `card`, and the only things that leave are the four action signals. It calls
// no backend and holds no state; the thread that hosts it owns both.
//
// An unknown kind renders nothing (implicitHeight 0, visible false), so the
// thread can fall back to a plain-text bubble. Every field is guarded, because
// a card is peer JSON: a missing field is normal, never an error.
//
// NB (ADR-011): nix build does not evaluate QML; a bad type name here blanks
// the whole view invisibly. Restricted to Theme keys and the Logos.Controls
// types Room.qml / Walkthrough.qml already prove — LogosText, LogosButton.
Rectangle {
    id: cardRoot
    objectName: "musterCard"

    // The parsed card object: { kind, ... }. Never assume more than `kind`.
    property var card

    // Whether the intent-propose verify box is expanded ("dive in"). Local render
    // state — the card holds no other state, but this is the reader's own toggle.
    property bool verifyOpen: false

    // Whether the provenance lineage ("how do I know this?") is expanded.
    property bool provOpen: false

    // When the reader taps "trace this" on a specific piece of the card (the effect,
    // the approvals), the lineage opens focused on that piece's class — its entries
    // are lit, the rest dimmed — so a card element leads straight to its own origin.
    // "" means no focus (the box was opened from its own header): show all evenly.
    property string provFocus: ""

    // Open the lineage focused on one input class (invariant-10 vocabulary), from a
    // tap on the card element that class produced. Idempotent, so tapping the same
    // trace again just keeps it open on that piece.
    function traceClass(cls) {
        cardRoot.provFocus = String(cls || "");
        cardRoot.provOpen = true;
    }

    // The trust line for one provenance entry: (named account) · why it can be
    // trusted, by class · the log position it came from. The "why" is what the code
    // already guarantees for that class — a driver-contribution was verified to
    // recover to a configured member; a peer-message was sealed to the room's epoch.
    function provTrust(item) {
        var cls = String((item && item["class"]) || "");
        var alias = String((item && item.alias) || "");
        var acct = String((item && item.account) || "");
        var pos = (item && item.logPos !== undefined) ? item.logPos : "";
        // WHO: the address-book name if we have one, else the short raw account.
        var who = alias.length > 0 ? alias
                : (acct.length > 0 ? acct.substring(0, 10) + "…" : "");
        // WHY: the guarantee the module states for this input (authoritative), with a
        // per-class fallback so an older payload still reads sensibly.
        var why = String((item && item.guarantee) || "");
        if (why.length === 0)
            why = cls === "driver-contribution" ? qsTr("verified member")
                : cls === "peer-message" ? qsTr("sealed to the room")
                : cls === "external-read" ? qsTr("read from chain")
                : cls === "plugin-block" ? qsTr("emitted by a plugin") : "";
        var parts = [];
        if (who.length > 0) parts.push(who);
        // an approval's grade (exo-ef1): whether it commits to its inputs
        var grade = String((item && item.attestation) || "");
        if (grade === "committed") parts.push(qsTr("committed — attested in muster"));
        else if (grade === "unattested") parts.push(qsTr("unattested — pasted from outside muster"));
        if (why.length > 0) parts.push(why);
        if (pos !== "") parts.push(qsTr("log #%1").arg(pos));
        return parts.join("  ·  ");
    }

    // A one-line "who is behind this" for the collapsed lineage header — the distinct
    // names (aliases where known) that contributed, so you see the people behind a
    // decision at a glance before diving into the full per-piece lineage.
    function provWho(prov) {
        if (!prov || prov.length === 0) return "";
        var names = [];
        for (var i = 0; i < prov.length; i++) {
            var it = prov[i];
            var who = String((it && it.alias) || "");
            if (who.length === 0) {
                var a = String((it && it.account) || "");
                who = a.length > 0 ? a.substring(0, 8) + "…" : "";
            }
            if (who.length > 0 && names.indexOf(who) === -1) names.push(who);
        }
        return names.join(", ");
    }

    // The verify rows, built off `card` (guarded — a missing field is normal).
    function verifyShown() {
        var stmt = String((cardRoot.card && cardRoot.card.statement) || "");
        if (stmt.length > 0)
            return "“" + stmt + "”";
        var amt = String((cardRoot.card && cardRoot.card.amount) || "");
        var den = String((cardRoot.card && cardRoot.card.denom) || "");
        var to = String((cardRoot.card && cardRoot.card.to) || "");
        var lead = (amt + " " + den).replace(/\s+/g, " ").trim();
        return to.length > 0 ? lead + "  →  " + to : lead;
    }
    // the card's fixed rows (exo-a50.1.6) and a lookup by key
    readonly property var rows: (cardRoot.card && Array.isArray(cardRoot.card.rows)) ? cardRoot.card.rows : []
    property bool rowsOpen: false
    function rowText(key) {
        for (var i = 0; i < cardRoot.rows.length; ++i)
            if (cardRoot.rows[i].key === key) return String(cardRoot.rows[i].text || "");
        return "";
    }
    function verifyDomain() {
        // the chain + account the signatures are bound to, from the family profile
        var prof = (cardRoot.card && cardRoot.card.profile) ? cardRoot.card.profile : null;
        if (prof && prof.chain) return String(prof.chain) + (prof.account ? "  ·  " + String(prof.account) : "");
        if (prof && prof.family) return qsTr("this room (%1)").arg(String(prof.family));
        var parts = [];
        var env = String((cardRoot.card && cardRoot.card.environment) || "");
        if (env.length > 0) parts.push(env);
        if (cardRoot.card && cardRoot.card.chainId)
            parts.push(qsTr("chain %1").arg(cardRoot.card.chainId));
        var sf = String((cardRoot.card && cardRoot.card.safe) || "");
        if (sf.length > 0) parts.push(qsTr("Safe %1").arg(sf));
        return parts.join("  ·  ");
    }

    // Actions belong to the reader, and the thread decides what each does. The
    // card only says which button was pressed.
    signal approve()
    // "What this needs" (exo-002.3): the card asks the room to load this intent's
    // readiness on first open (it probes the RPC, so it is on-demand, never on the tick).
    signal needs()
    // Decline to take part — informational, the threshold is unchanged.
    signal deny()
    // Save this intent's signature-audit file + report (exo-403).
    signal downloadAudit()
    // The outcome of the last download for THIS intent, set by the room ("" = none yet).
    property string auditStatus: ""
    // Share one of MY holdings to fill a slot this proposal asks of me (the "From you"
    // picker, exo-45e K6): (requirement name, the chosen candidate's PUBLIC face).
    signal shareMaterial(string requirement, string pub)
    // A remedy that lives in Settings (an RPC to configure / repoint).
    signal openSettings()
    // Install what's missing (exo-dcc.10): ask Basecamp's Package Manager to open on the
    // package a module need names; the person confirms the install there, never here.
    // The room relays it to the shell, and what each request answered comes back in
    // packageRequests (one entry per package, shared by every card and the form).
    signal installPackage(string pkg)
    signal showPackage(string pkg)
    // Re-read this intent's readiness (after Package Manager opened, until the module runs).
    signal recheckReadiness()
    property var packageRequests: ({})
    // need name → the package this card asked for it (the reader's own clicks)
    property var installAsked: ({})
    // the clock the 3-minute re-read window is judged against, advanced by its timer
    property double installNow: Date.now()
    function installReq(pkg) {
        var m = cardRoot.packageRequests;
        return (pkg && m && m[pkg]) ? m[pkg] : null;
    }
    // the package for a module need: what the module names, else what was asked for it
    function installPkg(item) {
        var p = String((item && item.install) || "");
        return p.length > 0 ? p : String(cardRoot.installAsked[String((item && item.name) || "")] || "");
    }
    // "Install …" only where installing would help: the module names a package, and the
    // module is not already installed (starting, failed or waiting to be opened).
    function canInstall(item) {
        if (!item || item.kind !== "module" || item.status === "met") return false;
        var st = String(item.moduleState || "");
        return String(item.install || "").length > 0
               && st !== "installed" && st !== "starting" && st !== "error" && st !== "ready";
    }
    function installNote(pkg, item) {
        var r = cardRoot.installReq(pkg);
        if (!r) return "";
        var st = String((item && item.moduleState) || "");
        // installed, starting, running or failed: the item's own detail and remedy say
        // what comes next, so a "Package Manager is open" line would only contradict them
        if (r.state === "open" && (st === "installed" || st === "starting" || st === "ready" || st === "error"))
            return "";
        if (r.state === "asking") return qsTr("Asking Package Manager to open %1…").arg(pkg);
        if (r.state === "open")
            return cardRoot.installLapsed(r)
                   // the 3-minute re-read is over: say how to look again, never a stale promise
                   ? qsTr("Package Manager was opened on %1. Check again once the install is done.").arg(pkg)
                   : qsTr("Package Manager is open on %1. Confirm the install there; this card updates once it is installed.").arg(pkg);
        if (r.state === "unavailable") return qsTr("Install %1 from Basecamp's Package Manager.").arg(pkg);
        if (r.state === "failed")
            return qsTr("%1 was not found in your catalogues. Check the catalogues in Package Manager.").arg(pkg);
        // the person cancelled Basecamp's "Use this app?" chooser, or a newer request
        // replaced this one: the broker answers both as cancelled
        if (r.state === "cancelled") return qsTr("The install request was cancelled.");
        return qsTr("Package Manager did not answer (%1). Install %2 from Basecamp's Package Manager.")
               .arg(String(r.error || "")).arg(pkg);
    }
    // Package Manager opened on it more than 3 minutes ago: the card no longer re-reads
    function installLapsed(r) {
        return !!(r && r.state === "open" && cardRoot.installNow - Number(r.at || 0) >= 180000);
    }
    function askInstall(item) {
        var pkg = String((item && item.install) || "");
        if (pkg.length === 0) return;
        var m = Object.assign({}, cardRoot.installAsked);
        m[String(item.name || "")] = pkg;
        cardRoot.installAsked = m;
        cardRoot.installNow = Date.now();
        cardRoot.installPackage(pkg);
    }
    // Whether a module this card needs is being installed: Package Manager answered ok on
    // its package less than 3 minutes ago, and readiness does not yet read it met.
    readonly property bool installAwaited: {
        var items = (cardRoot.readiness && Array.isArray(cardRoot.readiness.items)) ? cardRoot.readiness.items : [];
        for (var i = 0; i < items.length; ++i) {
            var it = items[i];
            if (!it || it.kind !== "module" || it.status === "met") continue;
            // installed but stopped, or failed: nothing changes until the person acts
            var st = String(it.moduleState || "");
            if (st === "installed" || st === "error") continue;
            var r = cardRoot.installReq(cardRoot.installPkg(it));
            if (r && r.state === "open" && cardRoot.installNow - Number(r.at || 0) < 180000) return true;
        }
        return false;
    }
    // Re-read readiness every 3 s while the box is open, for up to 3 minutes after
    // Package Manager opened, or until the module reads met. Stops with the card.
    Timer {
        interval: 3000
        repeat: true
        running: cardRoot.needsOpen && cardRoot.installAwaited
        onTriggered: {
            cardRoot.installNow = Date.now();
            if (cardRoot.installAwaited) cardRoot.recheckReadiness();
        }
    }
    property bool needsOpen: false
    readonly property var readiness: (cardRoot.card && cardRoot.card.readiness) ? cardRoot.card.readiness : null
    // "From you" (exo-45e K6): which of my own holdings fill the slots this asks of me.
    readonly property var offers: (cardRoot.card && cardRoot.card.offers) ? cardRoot.card.offers : null
    // The policy this intent runs under (from readiness), used to gate the picker below.
    readonly property string policy: (cardRoot.readiness && cardRoot.readiness.kind)
                                     ? String(cardRoot.readiness.kind)
                                     : (cardRoot.readiness && cardRoot.readiness.policy)
                                       ? String(cardRoot.readiness.policy).split("@")[0] : ""
    // The slots I fill by DISCLOSING material — an address or asset the effect needs
    // before it completes. Authority slots are excluded on purpose: those are filled by
    // SIGNING (the Approve button), never by sharing, so they don't belong in this picker.
    readonly property var shareableOffers: {
        var out = [];
        var offs = (cardRoot.offers && cardRoot.offers.offers) ? cardRoot.offers.offers : [];
        for (var i = 0; i < offs.length; ++i) {
            var k = (offs[i].requirement && offs[i].requirement.kind)
                    ? String(offs[i].requirement.kind) : "";
            if (k === "address" || k === "asset") out.push(offs[i]);
        }
        return out;
    }
    // The "From you" material-share picker (exo-45e K6/exo-647c) shows only when a driver
    // that CONSUMES shared material (invoke / Mode B, the coordinated transfer) asks me
    // for a slot I actually hold something for. Hidden for the Safe policy: its payee is
    // filled by the ask-then-disclose address card and it reaches threshold by SIGNING, so
    // a shared material folds into nothing the card shows (the old degenerate case). The
    // rest of "What this needs" (needs / touches / who-sees-what) shows regardless.
    readonly property bool showFromYou: {
        if (cardRoot.policy === "safe") return false;
        var offs = cardRoot.shareableOffers;
        for (var i = 0; i < offs.length; ++i)
            if (offs[i].status === "satisfiable" && offs[i].candidates
                && offs[i].candidates.length > 0) return true;
        return false;
    }
    readonly property int declines: cardRoot.card ? Number(cardRoot.card.declines || 0) : 0
    readonly property var decliners: (cardRoot.card && cardRoot.card.decliners) ? cardRoot.card.decliners : []
    readonly property bool declinedByMe: !!(cardRoot.card && cardRoot.card.declinedByMe)

    // The disclosure rows grouped by observer class, in a fixed honest order — the
    // room first, then everything OUTSIDE the boundary (store node, RPC, chain, module).
    function disclosureGroups() {
        var r = cardRoot.readiness;
        if (!r || !r.manifest || !r.manifest.discloses) return [];
        var order = ["room-member", "store-node", "rpc-provider", "chain-observer", "target-module"];
        var label = { "room-member": qsTr("the room"), "store-node": qsTr("the store node"),
                      "rpc-provider": qsTr("your RPC provider"), "chain-observer": qsTr("anyone reading the chain"),
                      "target-module": qsTr("the module it calls") };
        var groups = {};
        for (var i = 0; i < r.manifest.discloses.length; ++i) {
            var d = r.manifest.discloses[i];
            (groups[d.to] = groups[d.to] || []).push(String(d.field));
        }
        var out = [];
        for (var k = 0; k < order.length; ++k)
            if (groups[order[k]]) out.push({ to: order[k], label: label[order[k]] || order[k], fields: groups[order[k]].join(", ") });
        return out;
    }
    function agreementLine() {
        var r = cardRoot.readiness;
        if (!r || !r.manifest || !r.manifest.agreement) return "";
        var a = r.manifest.agreement;
        var s = qsTr("%1 of the signers").arg(a.threshold);
        if (Number(a.rounds || 1) > 1) s += qsTr(", over %1 rounds").arg(a.rounds);
        s += a.finality === "external" ? qsTr(" · settles outside the room") : qsTr(" · final in the room");
        return s;
    }
    function readinessSummary() {
        var r = cardRoot.readiness;
        if (!r) return "";
        if (r.error) return qsTr("could not check: %1").arg(String(r.error));
        if (!r.declared) return qsTr("this policy has not declared what it needs — nothing is guessed");
        if (r.ready) return qsTr("✓ you have everything this needs");
        var missing = 0;
        for (var i = 0; i < (r.items || []).length; ++i) if (r.items[i].status === "missing") ++missing;
        var parts = [];
        if (missing > 0) parts.push(qsTr("%1 missing").arg(missing));
        if (Number(r.unknown || 0) > 0) parts.push(qsTr("%1 unknown").arg(r.unknown));
        return parts.join(" · ");
    }
    // A split (exo-a90): pay MY share (the module derives it from the agreed split), or — as
    // the creditor — mark one person's share received outside muster.
    signal settlePart()
    signal confirmPart(string part)
    // A Monero request (exo-dcc.5): muster never sends Monero. A debtor pays from any wallet
    // with the monero: link the module derives from the agreed request, then says so —
    // "I paid", with the transaction id if they give one: their claim, never a
    // confirmation. The creditor's own open wallet confirms; when it cannot, the card
    // asks Monero Wallet to open it (the room raises the intent; its answer comes back in
    // moneroWalletNote, "" = nothing asked).
    signal reportPaid(string tx)
    signal openMoneroWallet(string wallet)
    property string moneroWalletNote: ""
    readonly property var xmr: (cardRoot.split && cardRoot.split.xmr) ? cardRoot.split.xmr : null
    readonly property bool isXmr: cardRoot.xmr !== null
    // MY share's link, if I owe one: {part, ok, uri, amount, payTo, why, reported, confirmed}
    readonly property var xmrPay: (cardRoot.xmr && cardRoot.xmr.payment) ? cardRoot.xmr.payment : null
    // on the creditor's client: whether their open wallet can confirm {ready, detail, code, request}
    readonly property var xmrWallet: (cardRoot.xmr && cardRoot.xmr.wallet) ? cardRoot.xmr.wallet : null
    readonly property int xmrDepth: cardRoot.xmr ? Number(cardRoot.xmr.confirmDepth || 10) : 10
    // a payment request: one share, and the creditor's own share nothing
    readonly property bool isRequest: cardRoot.isSplit && cardRoot.parts.length === 1
                                      && String(cardRoot.split.creditorShare || "") === "0"
    // a request's headline: who asks whom for what
    function requestLine() {
        if (!cardRoot.isRequest) return "";
        var p = cardRoot.parts[0];
        var who = String(p.name || "").length > 0 ? String(p.name) : String(p.who || "").slice(0, 10) + "…";
        var memo = String(cardRoot.split.memo || "").length > 0 ? " · " + String(cardRoot.split.memo) : "";
        return cardRoot.iAmCreditor
               ? qsTr("You ask %1 for %2 %3%4").arg(who).arg(cardRoot.eth(cardRoot.split.total)).arg(cardRoot.unit).arg(memo)
               : qsTr("%1 asks %2 for %3 %4%5").arg(cardRoot.creditorName).arg(who)
                     .arg(cardRoot.eth(cardRoot.split.total)).arg(cardRoot.unit).arg(memo);
    }
    // A wallet refusal in plain words: by its code where one says it better, else the
    // module's own words without the code and the intent's name
    // ("no-wallet: … (monero.wallet.unlock)").
    function xmrDetail(d, code) {
        var c = String(code || "");
        if (c === "no-wallet") return qsTr("no Monero wallet is open. Open it in Monero Wallet.");
        if (c === "wallet-watch-only") return qsTr("the open wallet is view-only. Open the wallet that can spend what it receives.");
        var t = String(d || "");
        var i = t.indexOf(": ");
        if (i > 0 && /^[a-z-]+$/.test(t.slice(0, i))) t = t.slice(i + 2);
        return t.replace(/ \(monero\.wallet\.unlock\)$/, "");
    }
    // A split past its expiry (exo-a90.15): renew its unpaid shares — a settle-up of it.
    signal renewSplit()
    readonly property bool splitExpired: !!(cardRoot.split && cardRoot.split.expired) && !cardRoot.paid
    // The last pay / confirm outcome for THIS split, set by the room ("" = none).
    property string splitNote: ""
    readonly property var split: (cardRoot.card && cardRoot.card.split) ? cardRoot.card.split : null
    readonly property bool isSplit: cardRoot.split !== null
    // A settle-up (exo-3c6): the net payments instead of the shares they cover.
    readonly property var settleUp: (cardRoot.card && cardRoot.card.settleUp) ? cardRoot.card.settleUp : null
    readonly property bool isSettleUp: cardRoot.settleUp !== null
    // Across chains (exo-a90.17): a payment to ME at an address I vouch for that this client
    // does not hold — my agreement would vouch for someone else's address, so it is not offered.
    readonly property bool vouchedNotMine: {
        if (!cardRoot.settleUp) return false;
        var ts = cardRoot.settleUp.transfers || [];
        for (var i = 0; i < ts.length; ++i) if (ts[i].toMe && ts[i].vouched && !ts[i].payToMine) return true;
        return false;
    }
    // whose quote the rates are: the signed proposer claim (exo-770) — "your rate" when it is mine
    readonly property string rateOwner: {
        var ps = (cardRoot.card && Array.isArray(cardRoot.card.proposedBy)) ? cardRoot.card.proposedBy : [];
        if (ps.length === 0) return qsTr("the proposer's rate");
        if (ps[0].mine) return qsTr("your rate");
        return qsTr("%1's rate").arg(String(ps[0].name || "") || String(ps[0].who || "").slice(0, 10) + "…");
    }
    // The next payment of mine to send: unsettled and not already on its way. A payer owing
    // two people may send the second while the first lands — the module skips what this host
    // has in flight, in the same order (exo-a90.18), so it pays the one this button names.
    readonly property var myTransfer: {
        if (!cardRoot.settleUp) return null;
        var ts = cardRoot.settleUp.transfers || [];
        for (var i = 0; i < ts.length; ++i) if (ts[i].mine && !ts[i].settled && !ts[i].paying) return ts[i];
        return null;
    }
    // A split's payTo, readable: an address stays whole; a shielded key node — ~200 hex
    // characters that no one reads and that would run off the card — is named as one and
    // shortened, the way the address-share card does.
    function shortPayTo(p) {
        if (p.indexOf("priv:") === 0)
            return qsTr("a shielded key node, %1…%2").arg(p.slice(5, 17)).arg(p.slice(-8));
        if (cardRoot.isXmr && p.length > 24) return p.slice(0, 12) + "…" + p.slice(-8);
        return p;
    }
    readonly property var parts: (cardRoot.card && Array.isArray(cardRoot.card.parts)) ? cardRoot.card.parts : []
    readonly property var myPart: {
        for (var i = 0; i < cardRoot.parts.length; ++i) if (cardRoot.parts[i].mine) return cardRoot.parts[i];
        return null;
    }
    readonly property bool iAmDebtor: cardRoot.myPart !== null
    readonly property bool iAmCreditor: !!(cardRoot.split && cardRoot.split.iAmCreditor)
    // The creditor is a party too (exo-770): their agreement is their word that payTo is
    // theirs — made at propose when they proposed it, else asked of them here.
    readonly property bool creditorAgreed: !!(cardRoot.split && cardRoot.split.creditorAgreed)
    readonly property bool payToMine: !!(cardRoot.split && cardRoot.split.payToMine)
    // a Monero creditor whose wallet has not yet listed its addresses (exo-dcc.20): not known —
    // never "not yours"; their client checks payTo against the wallet when they agree
    readonly property bool payToMineUnknown: !!(cardRoot.split && cardRoot.split.payToMineKnown === false)
    // Proposed by someone other than the creditor, on the creditor's behalf: named from
    // signed claims only — an unattributed proposal (an older room) says nothing.
    readonly property string onBehalfBy: {
        if (!cardRoot.split || !cardRoot.card || !Array.isArray(cardRoot.card.proposedBy)) return "";
        var names = [];
        for (var i = 0; i < cardRoot.card.proposedBy.length; ++i) {
            var p = cardRoot.card.proposedBy[i];
            if (String(p.who || "") === String(cardRoot.split.creditor || "")) return "";
            names.push(String(p.name || "").length > 0 ? String(p.name) : String(p.who || "").slice(0, 10) + "…");
        }
        return names.join(", ");
    }
    readonly property string creditorName: cardRoot.split
        ? (String(cardRoot.split.creditorName || "").length > 0 ? String(cardRoot.split.creditorName)
           : String(cardRoot.split.creditor || "").slice(0, 10) + "…") : ""
    // The split's asset and its decimals (ETH 18, LEZ 9): base units → a readable amount,
    // by string — never a float.
    // a token's own symbol (exo-5ab) — display only; its address is named on the card
    readonly property string unit: cardRoot.split ? String(cardRoot.split.symbol || cardRoot.split.asset || "ETH")
                                 : cardRoot.settleUp ? String(cardRoot.settleUp.symbol || cardRoot.settleUp.asset || "ETH") : "ETH"
    readonly property string token: cardRoot.split ? String(cardRoot.split.token || "") : ""
    readonly property int decimals: cardRoot.split ? Number(cardRoot.split.decimals || 18)
                                  : cardRoot.settleUp ? Number(cardRoot.settleUp.decimals || 18) : 18
    function eth(wei) {
        var dec = cardRoot.decimals;
        var s = String(wei || "0").replace(/^0+/, "");
        if (s.length === 0) return "0";
        while (s.length <= dec) s = "0" + s;
        var whole = s.slice(0, s.length - dec), frac = s.slice(s.length - dec).replace(/0+$/, "");
        return frac.length > 0 ? whole + "." + frac : whole;
    }
    // Where one person's share stands — only what they disclosed (their agreement, their
    // payment report) and what the creditor confirmed (invariant 9).
    function partState(p) {
        if (!p) return "";
        if (cardRoot.isXmr) {
            // only the creditor's own wallet confirms; a report is the debtor's claim
            if (p.confirmed) return String(p.tx || "").length > 0
                                    ? (cardRoot.iAmCreditor ? qsTr("✓ received — your wallet saw it at %1 confirmations").arg(cardRoot.xmrDepth)
                                       : qsTr("✓ received — %1's wallet saw it at %2 confirmations").arg(cardRoot.creditorName).arg(cardRoot.xmrDepth))
                                    : (cardRoot.iAmCreditor ? qsTr("✓ you marked it received")
                                       : qsTr("✓ marked received by %1").arg(cardRoot.creditorName));
            // n of 10 (exo-dcc.20): what the creditor's own wallet history shows, on their
            // client only — absent when nothing was seen or the read did not answer
            var seen = (p.confirmations !== undefined && p.confirmations !== null)
                       ? qsTr("seen, %1 of %2 confirmations").arg(Number(p.confirmations)).arg(cardRoot.xmrDepth) : "";
            if (p.settled) {
                var ref = String(p.tx || "").length > 0 ? " (" + String(p.tx).slice(0, 10) + "…)" : "";
                if (seen.length > 0) return qsTr("says they paid%1 — %2").arg(ref).arg(seen);
                return cardRoot.iAmCreditor
                       ? qsTr("says they paid%1 — your wallet confirms it at %2 confirmations").arg(ref).arg(cardRoot.xmrDepth)
                       : qsTr("says they paid%1 — waiting for %3's wallet to see it at %2 confirmations")
                             .arg(ref).arg(cardRoot.xmrDepth).arg(cardRoot.creditorName);
            }
            if (seen.length > 0) return seen;
        }
        if (p.confirmed) return String(p.tx || "").indexOf("note:") === 0 ? qsTr("✓ received — a private note of exactly this share")
                              : String(p.tx || "").length > 0 ? qsTr("✓ received")
                              : p.settledUp ? qsTr("✓ paid through a settle-up") : qsTr("✓ received outside muster");
        if (p.settled) return qsTr("paid (%1) — %2 has not seen it yet").arg(String(p.tx || "").slice(0, 10) + "…")
                                                                     .arg(cardRoot.creditorName);
        if (p.unresolved) return qsTr("sent — not landed by now; muster keeps watching and won't send it twice");
        if (p.paying) return qsTr("paying…");
        if (p.covered) return qsTr("in a settle-up — paid through it");
        var agreed = false;
        var ap = (cardRoot.card && Array.isArray(cardRoot.card.approvers)) ? cardRoot.card.approvers : [];
        for (var i = 0; i < ap.length; ++i) if (String(ap[i].who) === String(p.part)) agreed = true;
        return agreed ? (cardRoot.ready ? qsTr("agreed — to pay") : qsTr("agreed")) : qsTr("to agree");
    }
    signal shareAddress()
    // An address-request's answers and whom it asked (exo-8e2): Room.qml finds the
    // address-share cards posted after it of the kind asked ([{who, self, name, address}]).
    // A request naming a member ("for") is offered to them alone; one naming nobody, to
    // whoever has not answered it yet.
    property var answers: []
    property string readerIdentity: ""
    property string askedOfName: ""
    // this member posted this card: their own request is never theirs to answer, nor their
    // own shared address theirs to pay (exo-1d9)
    property bool postedByMe: false
    readonly property string askedOf: String((cardRoot.card && cardRoot.card["for"]) || "").toLowerCase().replace(/^0x/, "")
    readonly property bool askedOfMe: !cardRoot.postedByMe
                                      && (cardRoot.askedOf.length === 0
                                          || cardRoot.askedOf === cardRoot.readerIdentity.toLowerCase().replace(/^0x/, ""))
    readonly property bool answeredByMe: {
        var a = cardRoot.answers || [];
        for (var i = 0; i < a.length; ++i) if (a[i].self) return true;
        return false;
    }
    readonly property bool answeredByAsked: {
        if (cardRoot.askedOf.length === 0) return false;
        var a = cardRoot.answers || [];
        for (var i = 0; i < a.length; ++i) if (String(a[i].who) === cardRoot.askedOf) return true;
        return false;
    }
    // Use a disclosed public address as the recipient of a payment being composed —
    // closes the ask→disclose→use loop so the proposer never retypes what a peer just
    // shared into the room (the counterparty's address for the Safe txn).
    signal useAddress(string address)

    readonly property string kind: cardRoot.card ? String(cardRoot.card.kind || "") : ""

    // The kinds this component knows how to draw. Anything else is not ours to
    // render, so we disappear and let the thread show plain text.
    readonly property bool known:
        cardRoot.kind === "address-request"
        || cardRoot.kind === "address-share"
        || cardRoot.kind === "intent-propose"
        || cardRoot.kind === "intent-approve"
        || cardRoot.kind === "send-receipt"

    // Schema-driven rendering (exo-1ec.3): an activity renders ONLY from a declared,
    // versioned schema. schemaKnown defaults TRUE (an older payload with no field renders
    // as before); an explicit false means muster has no schema for this effect, so the
    // card draws a NAMED "schema unknown" failure instead of the body — never a silent
    // fallback that shows it as a payment it is not, and never a blank pane.
    readonly property bool schemaKnown:
        !(cardRoot.card && cardRoot.card.schemaKnown === false)
    readonly property string schemaId: cardRoot.card ? String(cardRoot.card.schemaId || "") : ""

    // ── intent-propose reading ────────────────────────────────────────────
    // The terms come off the card; the live counts do too, since this build
    // has no fold to consult — so guard each one and never invent a default
    // that would overstate agreement.
    readonly property string state: cardRoot.card && cardRoot.card.state
        ? String(cardRoot.card.state) : "proposed"
    readonly property int threshold: cardRoot.card ? Number(cardRoot.card.threshold || 0) : 0
    // How many could sign (owners / roster) — the "N" in "M of N". Falls back to the
    // threshold when absent, so an older card never reads "2 of 0".
    readonly property int signerCount: cardRoot.card
        ? Number(cardRoot.card.n || cardRoot.card.threshold || 0) : 0
    readonly property int approvals: cardRoot.card ? Number(cardRoot.card.approvals || 0) : 0
    // exo-ef1: approvals signed in muster commit to their inputs (attested); ones signed
    // elsewhere and pasted in count, but commit to nothing beyond the transaction.
    readonly property int unattested: cardRoot.card ? Number(cardRoot.card.unattested || 0) : 0
    // Multi-round (FROST): how many rounds the driver runs, which round is collecting,
    // and the distinct approvals THIS round. rounds == 1 for single-round drivers, and
    // the round chrome then stays hidden.
    readonly property int rounds: cardRoot.card ? Number(cardRoot.card.rounds || 1) : 1
    readonly property int roundNo: cardRoot.card ? Number(cardRoot.card.round || 1) : 1
    readonly property int roundApprovals: cardRoot.card ? Number(cardRoot.card.roundApprovals || 0) : 0
    readonly property bool paid: cardRoot.state === "paid"
    // "Ready" means the intent has collected enough to act — by the authoritative
    // folded state (executable/ready), or, for a SINGLE-round driver only, by the
    // approval count reaching the threshold. A multi-round driver must NOT use the
    // count heuristic: distinct approvals accrue across rounds, so it would read
    // ready after round 1; only the folded state (executable) is authoritative there.
    readonly property bool ready: cardRoot.state === "ready" || cardRoot.state === "executable"
        || cardRoot.paid
        || (cardRoot.rounds <= 1 && cardRoot.threshold > 0 && cardRoot.approvals >= cardRoot.threshold)

    visible: cardRoot.known
    Layout.fillWidth: true
    implicitHeight: cardRoot.known ? body.implicitHeight + 2 * Theme.spacing.medium : 0

    radius: Theme.spacing.radiusMedium
    // The receipt is the one moment value leaves the room, so it carries the
    // outside ground inside it — every other kind stays on the raised surface.
    color: cardRoot.kind === "send-receipt"
        ? Theme.palette.surfaceRecessed
        : Theme.palette.surfaceRaised
    border.width: 1
    border.color: Theme.palette.borderSubtle

    ColumnLayout {
        id: body
        anchors.fill: parent
        anchors.margins: Theme.spacing.medium
        spacing: Theme.spacing.tiny

        // ── a one-line heading, in mono — the "this is data" voice ─────────
        LogosText {
            Layout.fillWidth: true
            text: cardRoot.kind === "address-request" ? qsTr("Asked for an address")
                : cardRoot.kind === "address-share" ? qsTr("Shared an address")
                : cardRoot.kind === "intent-propose"
                  ? (String((cardRoot.card && cardRoot.card.heading) || "").length > 0 ? String(cardRoot.card.heading)
                     : String((cardRoot.card && cardRoot.card.statement) || "").length > 0 ? qsTr("Proposed a statement")
                     : String((cardRoot.card && cardRoot.card.action) || "").length > 0 ? qsTr("Proposed an action")
                     : qsTr("Proposed a payment"))
                : cardRoot.kind === "intent-approve" ? qsTr("Approved")
                : qsTr("Payment sent")
            color: cardRoot.kind === "send-receipt"
                ? Theme.palette.textSecondary
                : Theme.palette.textTertiary
            font.family: Theme.typography.mono
            font.pixelSize: Theme.typography.badgeText
            font.weight: Theme.typography.weightMedium
        }

        // ── address-request ────────────────────────────────────────────────
        // Primed by the room's intention: it names what the room is for and asks
        // whoever holds the needed address to share it.
        ColumnLayout {
            visible: cardRoot.kind === "address-request"
            Layout.fillWidth: true
            spacing: 2

            LogosText {
                visible: cardRoot.card && cardRoot.card.purpose
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("For: %1").arg(String((cardRoot.card && cardRoot.card.purpose) || ""))
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.primaryText
                font.weight: Theme.typography.weightMedium
            }
            LogosText {
                // the ask, while it is still yours to answer
                objectName: "cardAddressAsk"
                visible: cardRoot.askedOfMe && !cardRoot.answeredByMe
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                readonly property string askAsset: String((cardRoot.card && cardRoot.card.asset) || "ETH")
                readonly property string askChain: String((cardRoot.card && (cardRoot.card.chainLabel || cardRoot.card.chain)) || "")
                text: askAsset === "BTC"
                      ? qsTr("This room needs a Bitcoin address on %1 to pay you at. Sharing gives your own key's address there.").arg(askChain)
                      // exo-dcc.20: a fresh subaddress your own open wallet makes for the room
                      : askAsset === "XMR"
                      ? qsTr("This room needs a Monero address on %1 to pay you at. Sharing asks your own open Monero wallet for a new address; your client checks it is yours before you agree to anything paid there.").arg(askChain)
                      : qsTr("This room needs somewhere to send funds. Share an address to continue.")
                color: Theme.palette.textSecondary
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.secondaryText
            }
            LogosText {
                objectName: "cardAddressWaiting"
                visible: !cardRoot.askedOfMe && (cardRoot.askedOf.length > 0 ? !cardRoot.answeredByAsked
                                                                             : (cardRoot.answers || []).length === 0)
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: cardRoot.askedOf.length > 0 ? qsTr("Waiting for %1 to share an address.").arg(cardRoot.askedOfName || qsTr("them"))
                                                  : qsTr("Waiting for someone in the room to share an address.")
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.secondaryText
            }
            Repeater {
                model: cardRoot.answers || []
                delegate: LogosText {
                    required property var modelData
                    objectName: "cardAddressAnswer"
                    Layout.fillWidth: true
                    wrapMode: Text.WrapAnywhere
                    readonly property string shortAddr: {
                        var a = String(modelData.address || "");
                        return a.length > 18 ? a.slice(0, 10) + "…" + a.slice(-6) : a;
                    }
                    text: modelData.self ? qsTr("✓ You shared %1").arg(shortAddr)
                                         : qsTr("✓ %1 shared %2").arg(String(modelData.name || "")).arg(shortAddr)
                    color: Theme.palette.success
                    font.pixelSize: Theme.typography.secondaryText
                }
            }
        }

        // ── address-share ({asset, address, form}) ─────────────────────────
        ColumnLayout {
            visible: cardRoot.kind === "address-share"
            Layout.fillWidth: true
            spacing: Theme.spacing.tiny

            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: cardRoot.card && cardRoot.card.asset
                    ? String(cardRoot.card.asset) : qsTr("private account")
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.primaryText
            }

            // What kind of destination it is matters more than the sixty
            // characters no one reads — so name the form, then show a clipped
            // address after it. `form` 0 is shielded, 1 is a public account;
            // getting this wrong is the exact lie a labelled address must not
            // tell, so an absent form reads as the safer "shielded".
            LogosText {
                objectName: "cardShareForm"
                Layout.fillWidth: true
                wrapMode: Text.WrapAnywhere
                elide: Text.ElideRight
                text: {
                    var form = cardRoot.card && cardRoot.card.form !== undefined
                        ? Number(cardRoot.card.form) : 0;
                    var addr = cardRoot.card && cardRoot.card.address
                        ? String(cardRoot.card.address).replace(/\s+/g, "") : "";
                    var shown = addr.slice(0, 48) + (addr.length > 48 ? "…" : "");
                    // a Monero subaddress is no public account (exo-dcc.20): the chain shows no
                    // payer, payee or amount for what lands there
                    var xmr = String((cardRoot.card && cardRoot.card.asset) || "") === "XMR";
                    return (xmr ? qsTr("Monero subaddress") : form === 1 ? qsTr("public account") : qsTr("shielded"))
                        + (shown.length > 0 ? "  ·  " + shown : "");
                }
                color: Theme.palette.textTertiary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.secondaryText
            }

            // A public account is worth a word: the payer should know the
            // destination is readable before choosing how to pay. "Zone" is the
            // LEZ's word; on Ethereum or Bitcoin it is the chain (exo-4d4).
            LogosText {
                objectName: "cardShareReadable"
                Layout.fillWidth: true
                visible: cardRoot.card && cardRoot.card.form !== undefined
                    && Number(cardRoot.card.form) === 1
                wrapMode: Text.WordWrap
                text: String((cardRoot.card && cardRoot.card.asset) || "") === "XMR"
                      ? qsTr("The chain shows no payer, payee or amount: only the wallet that holds this address sees what lands here.")
                      : (String((cardRoot.card && cardRoot.card.chain) || "").indexOf("lez:") === 0
                       || String((cardRoot.card && cardRoot.card.asset) || "") === "LEZ")
                      ? qsTr("Anyone reading the zone can see what lands here.")
                      : qsTr("Anyone reading the chain can see what lands here.")
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.badgeText
            }

            // Close the loop: use the address the counterparty just disclosed as the
            // recipient of the payment being composed, instead of retyping it. Only for
            // a public account (form 1) that carries an address, and never on the
            // reader's own card: that would pay themselves (exo-1d9).
            LogosButton {
                objectName: "cardUseAddress"
                visible: cardRoot.card && !cardRoot.postedByMe && Number(cardRoot.card.form || 0) === 1
                    && String(cardRoot.card.asset || "") !== "XMR"     // muster never sends Monero
                    && String((cardRoot.card && cardRoot.card.address) || "").replace(/\s+/g, "").length > 0
                Layout.fillWidth: true
                text: qsTr("Use as recipient")
                variant: LogosButton.Variant.Secondary
                onClicked: cardRoot.useAddress(
                    String(cardRoot.card.address).replace(/\s+/g, ""))
            }
        }

        // ── intent-approve ─────────────────────────────────────────────────
        // Deliberately thin: an approval is a fact in the thread, not a thing
        // to act on. It earns a line so the record reads in order, no more.
        LogosText {
            visible: cardRoot.kind === "intent-approve"
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: qsTr("Added to the proposal above.")
            color: Theme.palette.text
            font.family: Theme.typography.publicSans
            font.pixelSize: Theme.typography.primaryText
        }

        // ── schema unknown (exo-1ec.3) ─────────────────────────────────────
        // A proposal whose effect declares a schema muster does not recognize. We
        // render a NAMED failure — what was declared, and why nothing is shown from it
        // — rather than coercing it to a payment or leaving a blank pane. There is no
        // Approve here: you cannot endorse bytes the app cannot re-derive (F-4).
        ColumnLayout {
            objectName: "cardSchemaUnknown"
            visible: cardRoot.kind === "intent-propose" && !cardRoot.schemaKnown
            Layout.fillWidth: true
            spacing: Theme.spacing.tiny

            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("⚠ Schema unknown")
                color: Theme.palette.warning
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.primaryText
                font.weight: Theme.typography.weightBold
            }
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("This activity declares “%1”, a schema this app does not recognize. "
                         + "Nothing is rendered from it — an activity is shown only from a "
                         + "declared, versioned schema, so it is never displayed as something "
                         + "it is not.").arg(cardRoot.schemaId.length > 0 ? cardRoot.schemaId
                                                                          : qsTr("an unknown effect"))
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.badgeText
            }
        }

        // ── intent-propose (the heart) ─────────────────────────────────────
        // The room deciding something before anyone acts on it. The effect
        // leads (amount → destination), a status rail shows how far it has
        // got, and approvals are drawn as filled slots — because "who is still
        // to weigh in" is the question people actually have.
        ColumnLayout {
            visible: cardRoot.kind === "intent-propose" && cardRoot.schemaKnown
            Layout.fillWidth: true
            spacing: Theme.spacing.tiny

            // header: label · M of N  (· round R of N for multi-round)
            LogosText {
                objectName: "cardHeader"
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: {
                    var label = cardRoot.card && cardRoot.card.label
                        ? String(cardRoot.card.label) : qsTr("Proposal");
                    var head = cardRoot.threshold > 0
                        ? label + "  ·  " + qsTr("%1 of %2").arg(cardRoot.threshold)
                                                            .arg(cardRoot.signerCount)
                        : label;
                    // FROST-style multi-round: name the round being collected and the
                    // distinct approvals in it — the honest "M of k this round".
                    if (cardRoot.rounds > 1 && !cardRoot.ready)
                        head += "  ·  " + qsTr("round %1 of %2 (%3 of %4 this round)")
                                    .arg(cardRoot.roundNo).arg(cardRoot.rounds)
                                    .arg(cardRoot.roundApprovals).arg(cardRoot.threshold);
                    else if (cardRoot.rounds > 1)
                        head += "  ·  " + qsTr("%1 rounds complete").arg(cardRoot.rounds);
                    return head;
                }
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.primaryText
                font.weight: Theme.typography.weightBold
            }

            // the effect. A statement shows its text (quoted); a payment shows
            // amount denom → to. A statement carries no destination — it is a group
            // endorsement, not a transfer.
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                visible: text.length > 0
                text: {
                    // a generic module action (P-D4): "call module.method(N args)" — the
                    // action lives in the effect, not the driver, so the card reads it off
                    // the effect the same way it reads a payment's amount → destination.
                    var act = String((cardRoot.card && cardRoot.card.action) || "");
                    if (act.length > 0) {
                        var args = (cardRoot.card && cardRoot.card.actionArgs)
                                 ? cardRoot.card.actionArgs : [];
                        var n = args.length;
                        return qsTr("call %1(%2)").arg(act)
                            .arg(n === 0 ? "" : qsTr("%1 %2").arg(n)
                                 .arg(n === 1 ? qsTr("arg") : qsTr("args")));
                    }
                    var stmt = String((cardRoot.card && cardRoot.card.statement) || "");
                    if (stmt.length > 0)
                        return "“" + stmt + "”";
                    var amt = String((cardRoot.card && cardRoot.card.amount) || "");
                    var den = String((cardRoot.card && cardRoot.card.denom) || "");
                    var to = String((cardRoot.card && cardRoot.card.to) || "");
                    var lead = (amt + " " + den).trim();
                    return to.length > 0 ? lead + "  →  " + to : lead;
                }
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.subtitleText
                font.weight: Theme.typography.weightMedium
            }

            // ── a settle-up (exo-3c6): the net payments instead, and where each stands ──
            ColumnLayout {
                objectName: "cardSettleUp"
                visible: cardRoot.isSettleUp
                Layout.fillWidth: true
                spacing: 2

                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: cardRoot.settleUp
                          // fewer payments than shares: netting ("instead of"); as many: a renewal,
                          // each share paid again as it was (exo-a90.15) — "for"
                          ? ((cardRoot.settleUp.transfers || []).length < Number(cardRoot.settleUp.covers || 0)
                             ? qsTr("Settle up%1 — %2 instead of %3 from %4") : qsTr("Settle up%1 — %2 for %3 from %4"))
                                .arg(String(cardRoot.settleUp.memo || "").length > 0 ? " · " + String(cardRoot.settleUp.memo) : "")
                                .arg((cardRoot.settleUp.transfers || []).length === 1 ? qsTr("1 payment")
                                     : qsTr("%1 payments").arg((cardRoot.settleUp.transfers || []).length))
                                .arg(Number(cardRoot.settleUp.covers || 0) === 1 ? qsTr("1 share")
                                     : qsTr("%1 shares").arg(Number(cardRoot.settleUp.covers || 0)))
                                .arg(Number(cardRoot.settleUp.splits || 0) === 1 ? qsTr("1 split")
                                     : qsTr("%1 splits").arg(Number(cardRoot.settleUp.splits || 0)))
                          : ""
                    color: Theme.palette.text
                    font.family: Theme.typography.publicSans
                    font.pixelSize: Theme.typography.subtitleText
                    font.weight: Theme.typography.weightMedium
                }
                // across assets and chains (exo-a90.17): what it covers, and each rate — the
                // proposer's quote, named before anyone agrees, like a fiat bill's
                LogosText {
                    objectName: "cardSettleUpAcross"
                    visible: !!(cardRoot.settleUp && cardRoot.settleUp.across)
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: {
                        if (!cardRoot.settleUp || !cardRoot.settleUp.across) return "";
                        var as = (cardRoot.settleUp.coverAssets || []).map(function (a) {
                            return qsTr("%1 on %2").arg(String(a.symbol || a.asset)).arg(String(a.chainLabel || a.chain));
                        });
                        return qsTr("Covers shares in %1; every payment is %2 on %3.")
                               .arg(as.join(", ")).arg(cardRoot.unit)
                               .arg(String(cardRoot.settleUp.chainLabel || cardRoot.settleUp.chain || ""));
                    }
                    color: Theme.palette.textSecondary
                    font.pixelSize: Theme.typography.secondaryText
                }
                Repeater {
                    model: (cardRoot.settleUp && cardRoot.settleUp.across) ? (cardRoot.settleUp.rates || []) : []
                    delegate: LogosText {
                        required property var modelData
                        objectName: "cardSettleUpRate"
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: String(modelData.perUnit || "").length > 0
                              ? qsTr("1 %1 = %2 %3 — %4, from “%5”, %6")
                                    .arg(String(modelData.symbol || modelData.asset)).arg(cardRoot.eth(modelData.perUnit))
                                    .arg(cardRoot.unit).arg(cardRoot.rateOwner).arg(String(modelData.source || ""))
                                    .arg(new Date(Number(modelData.at) * 1000).toLocaleString(Qt.locale(), Locale.ShortFormat))
                              : qsTr("%1 %2 base units per %3 base units of %4 — %5, from “%6” (this client could not read %4's decimals)")
                                    .arg(String(modelData.rate)).arg(cardRoot.unit).arg(String(modelData.per))
                                    .arg(String(modelData.symbol || modelData.asset)).arg(cardRoot.rateOwner)
                                    .arg(String(modelData.source || ""))
                        color: Theme.palette.text
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                    }
                }
                LogosText {
                    visible: !!(cardRoot.settleUp && cardRoot.settleUp.across)
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: qsTr("Agreeing means trusting these rates: check them first. Each share is converted at its rate, rounded down; nothing in muster makes a rate fair.")
                    color: Theme.palette.warning
                    font.pixelSize: Theme.typography.badgeText
                }
                Repeater {
                    model: cardRoot.settleUp ? (cardRoot.settleUp.transfers || []) : []
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosText {
                            Layout.preferredWidth: 220
                            elide: Text.ElideRight
                            text: (String(modelData.fromName || "") || String(modelData.from).slice(0, 10) + "…") + "  →  "
                                  + (String(modelData.toName || "") || String(modelData.to).slice(0, 10) + "…")
                            color: Theme.palette.text
                            font.pixelSize: Theme.typography.secondaryText
                        }
                        LogosText {
                            text: qsTr("%1 %2").arg(cardRoot.eth(modelData.amount)).arg(cardRoot.unit)
                            color: Theme.palette.textSecondary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }
                        LogosText {
                            Layout.fillWidth: true
                            text: modelData.confirmed ? qsTr("received ✓") : modelData.settled ? qsTr("paid — awaiting the recipient's read")
                                  : modelData.unresolved ? qsTr("sent — not landed yet, still watched")
                                  : modelData.paying ? qsTr("paying…") : cardRoot.settleUp.expired ? qsTr("expired")
                                  : cardRoot.ready ? qsTr("to pay") : qsTr("once everyone agrees")
                            color: modelData.confirmed ? Theme.palette.success : Theme.palette.textTertiary
                            font.pixelSize: Theme.typography.badgeText
                        }
                    }
                }
                // a recipient owed only on other chains is paid at an address they vouch for
                Repeater {
                    model: cardRoot.settleUp ? (cardRoot.settleUp.transfers || []).filter(function (t) { return t.vouched; }) : []
                    delegate: LogosText {
                        required property var modelData
                        objectName: "cardSettleUpVouched"
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: modelData.toMe && !modelData.payToMine
                              ? qsTr("⚠ You would be paid at %1, which this client does not hold — so it will not agree for you.")
                                    .arg(String(modelData.payTo))
                              : modelData.toMe
                              ? qsTr("You are paid at %1 — the address you shared for this chain; your agreement vouches for it.")
                                    .arg(String(modelData.payTo))
                              : qsTr("%1 is paid at %2 — an address %1 shared for this chain; their agreement vouches for it.")
                                    .arg(String(modelData.toName || "") || String(modelData.to).slice(0, 10) + "…")
                                    .arg(String(modelData.payTo))
                        color: modelData.toMe && !modelData.payToMine ? Theme.palette.warning : Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }
                }
                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: cardRoot.settleUp && cardRoot.settleUp.across
                          ? qsTr("Each member's balance across these splits is kept exactly, at these rates. Once agreed, the covered shares are paid only through this; once its payments are received, each creditor marks the shares it covered received, on whatever chain they were.")
                          : qsTr("Each member's balance across these splits is kept exactly; each person is paid where their own split said. Once agreed, the covered shares are paid only through this; once its payments are received, each creditor marks the shares it covered received.")
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.badgeText
                }
                // expired before anyone paid (exo-a90.16): it pays nothing more, and after a
                // day's grace — for a payment sent just before the expiry — it covers nothing
                LogosText {
                    objectName: "cardSettleUpExpired"
                    visible: !!(cardRoot.settleUp && cardRoot.settleUp.expired)
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: !cardRoot.settleUp ? ""
                          : cardRoot.settleUp.lapsed
                          ? qsTr("Expired before anyone paid. It no longer covers its shares: each can be paid directly again, or settled up anew.")
                          : qsTr("Expired before anyone paid. Its shares are released %1, in case a payment sent just before the expiry is still to be reported.")
                                .arg(new Date(Number(cardRoot.settleUp.releasesAt) * 1000).toLocaleString(Qt.locale(), Locale.ShortFormat))
                    color: Theme.palette.warning
                    font.pixelSize: Theme.typography.badgeText
                }
            }

            // ── a split (exo-a90): who owes whom what, and where each share stands ──
            ColumnLayout {
                objectName: "cardSplit"
                visible: cardRoot.isSplit
                Layout.fillWidth: true
                spacing: 2

                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: cardRoot.isRequest
                          ? cardRoot.requestLine()
                          : cardRoot.split
                          ? qsTr("%1 %2%3 — %4 paid; %5%6")
                                .arg(cardRoot.eth(cardRoot.split.total)).arg(cardRoot.unit)
                                .arg(String(cardRoot.split.memo || "").length > 0 ? " · " + String(cardRoot.split.memo) : "")
                                .arg(cardRoot.creditorName)
                                .arg(cardRoot.parts.length === 1 ? qsTr("1 person owes a share")
                                                                 : qsTr("%1 people owe a share").arg(cardRoot.parts.length))
                                .arg(cardRoot.split.private ? qsTr(" · private: the chain names no one") : "")
                          : ""
                    color: Theme.palette.text
                    font.family: Theme.typography.publicSans
                    font.pixelSize: Theme.typography.subtitleText
                    font.weight: Theme.typography.weightMedium
                }

                Repeater {
                    model: cardRoot.parts
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosText {
                            Layout.preferredWidth: 110
                            elide: Text.ElideRight
                            text: String(modelData.name || "").length > 0 ? String(modelData.name)
                                  : String(modelData.who || "").slice(0, 10) + "…"
                            color: Theme.palette.text
                            font.pixelSize: Theme.typography.secondaryText
                        }
                        LogosText {
                            text: qsTr("%1 %2").arg(cardRoot.eth(modelData.amount)).arg(cardRoot.unit)
                            color: Theme.palette.textSecondary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }
                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: cardRoot.partState(modelData)
                            color: modelData.confirmed ? Theme.palette.success
                                 : modelData.settled ? Theme.palette.textSecondary : Theme.palette.textTertiary
                            font.pixelSize: Theme.typography.badgeText
                        }
                        // the creditor's word: a share paid in cash, or anywhere muster cannot see
                        LogosButton {
                            objectName: "cardMarkReceived"
                            visible: cardRoot.iAmCreditor && cardRoot.ready && !cardRoot.paid && !modelData.confirmed
                            text: qsTr("Mark received")
                            variant: LogosButton.Variant.Secondary
                            onClicked: cardRoot.confirmPart(String(modelData.part || ""))
                        }
                    }
                }

                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    visible: cardRoot.split !== null
                    text: cardRoot.isRequest
                          ? qsTr("Paid to %1%2.").arg(cardRoot.shortPayTo(String((cardRoot.split && cardRoot.split.payTo) || "")))
                                .arg(!cardRoot.isXmr ? ""
                                     : cardRoot.iAmCreditor ? qsTr(", a subaddress of your own Monero wallet on %1")
                                                                  .arg(String(cardRoot.xmr.chainLabel || ""))
                                     : qsTr(", a subaddress of %1's own Monero wallet on %2")
                                           .arg(cardRoot.creditorName).arg(String(cardRoot.xmr.chainLabel || "")))
                          : cardRoot.split
                          ? qsTr("%1 own share: %2 %3 (it absorbs any rounding). Paid to %4.")
                                .arg(cardRoot.iAmCreditor ? qsTr("Your") : cardRoot.creditorName + qsTr("'s"))
                                .arg(cardRoot.eth(cardRoot.split.creditorShare)).arg(cardRoot.unit)
                                .arg(cardRoot.shortPayTo(String((cardRoot.split && cardRoot.split.payTo) || "")))
                          : ""
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.badgeText
                }

                // a bill in fiat (exo-3a4): the quote everyone agreeing is trusting — named, sourced,
                // timed — so it is checked before anyone agrees, not after
                LogosText {
                    objectName: "cardSplitQuote"
                    readonly property var q: (cardRoot.split && cardRoot.split.quote) ? cardRoot.split.quote : null
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    visible: q !== null
                    text: {
                        if (!q) return "";
                        var fd = Number(q.fiatDecimals || 2), r = String(q.fiatTotal || "0");
                        while (r.length <= fd) r = "0" + r;
                        var fiat = fd === 0 ? r : r.slice(0, r.length - fd) + "." + r.slice(r.length - fd);
                        var who = (cardRoot.card && Array.isArray(cardRoot.card.proposedBy) && cardRoot.card.proposedBy.length > 0)
                                  ? String(cardRoot.card.proposedBy[0].name || "") : "";
                        var when = new Date(Number(q.at || 0) * 1000).toLocaleString(Qt.locale(), Locale.ShortFormat);
                        return qsTr("A bill of %1 %2, converted at 1 %2 = %3 %4 — %5 quote, from “%6”, %7. Agreeing means trusting this rate: check it first.")
                               .arg(fiat).arg(String(q.currency)).arg(cardRoot.eth(String(q.rateAsset))).arg(cardRoot.unit)
                               .arg(who === "you" ? qsTr("your") : who.length > 0 ? who + qsTr("'s") : qsTr("the proposer's"))
                               .arg(String(q.source)).arg(when);
                    }
                    color: Theme.palette.warning
                    font.pixelSize: Theme.typography.badgeText
                }

                // a split paid in a token: which token, by address — its symbol is its own claim
                LogosText {
                    objectName: "cardSplitToken"
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    visible: cardRoot.token.length > 0
                    text: qsTr("Paid in %1 — the token at %2 (a token names itself; the address is what counts).")
                              .arg(cardRoot.unit).arg(cardRoot.token.slice(0, 10) + "…" + cardRoot.token.slice(-6))
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.badgeText
                }

                // on someone's behalf (exo-770): who proposed it, and whether the creditor has
                // said payTo is theirs — nobody pays before they do
                LogosText {
                    objectName: "cardSplitOnBehalf"
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    visible: cardRoot.onBehalfBy.length > 0
                    text: cardRoot.creditorAgreed && cardRoot.iAmCreditor
                          ? qsTr("Proposed by %1 on your behalf. ✓ You agreed that %2 is yours.")
                                .arg(cardRoot.onBehalfBy).arg(cardRoot.shortPayTo(String((cardRoot.split && cardRoot.split.payTo) || "")))
                          : cardRoot.creditorAgreed
                          ? qsTr("Proposed by %1 on %2's behalf. ✓ %2 agreed the address is theirs.")
                                .arg(cardRoot.onBehalfBy).arg(cardRoot.creditorName)
                          : cardRoot.iAmCreditor
                          ? qsTr("Proposed by %1 on your behalf. Nobody pays until you agree that %2 is yours.")
                                .arg(cardRoot.onBehalfBy).arg(cardRoot.shortPayTo(String((cardRoot.split && cardRoot.split.payTo) || "")))
                          : qsTr("Proposed by %1 on %2's behalf. Nobody pays until %2 agrees the address is theirs.")
                                .arg(cardRoot.onBehalfBy).arg(cardRoot.creditorName)
                    color: cardRoot.creditorAgreed ? Theme.palette.textSecondary : Theme.palette.warning
                    font.pixelSize: Theme.typography.badgeText
                }
                // the creditor's own client: a payTo it does not hold is never agreed to
                LogosText {
                    objectName: "cardSplitPayToNotMine"
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    visible: cardRoot.iAmCreditor && !cardRoot.creditorAgreed && !cardRoot.payToMine && !cardRoot.payToMineUnknown
                    text: qsTr("⚠ %1 is not an address this client holds, so muster will not agree for you: payments would go to whoever holds it. Share your own address and ask for the split again.")
                              .arg(cardRoot.shortPayTo(String(cardRoot.split ? cardRoot.split.payTo || "" : "")))
                    color: Theme.palette.warning
                    font.pixelSize: Theme.typography.badgeText
                }

                LogosText {
                    objectName: "cardMyShare"
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    visible: cardRoot.iAmDebtor && !cardRoot.isXmr
                    text: cardRoot.myPart
                          ? qsTr("Your share: %1 %2 → %3, from your own wallet%4. Muster builds the payment from this split — nothing to type, and nothing else can be sent.")
                                .arg(cardRoot.eth(cardRoot.myPart.amount)).arg(cardRoot.unit).arg(cardRoot.creditorName)
                                .arg(cardRoot.split && cardRoot.split.private ? qsTr(", on the private rail") : "")
                          : ""
                    color: Theme.palette.textSecondary
                    font.pixelSize: Theme.typography.badgeText
                }

                // ── a Monero request (exo-dcc.5): MY share's link, from the module's
                // projection — derived from the request everyone agreed, never typed ──
                ColumnLayout {
                    id: xmrPayBox
                    objectName: "cardXmrPay"
                    visible: cardRoot.isXmr && cardRoot.iAmDebtor && cardRoot.xmrPay !== null
                    Layout.fillWidth: true
                    spacing: Theme.spacing.tiny
                    readonly property var pay: cardRoot.xmrPay || ({})
                    readonly property bool linkShown: !!pay.ok && !pay.reported && !pay.confirmed && !cardRoot.splitExpired

                    LogosText {
                        objectName: "cardXmrPayLine"
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: {
                            var p = xmrPayBox.pay;
                            if (p.confirmed) return qsTr("✓ %1's wallet confirmed your payment.").arg(cardRoot.creditorName);
                            if (p.reported)
                                return qsTr("You said you paid. %1's own wallet confirms it once it has %2 confirmations (about 20 minutes).")
                                       .arg(cardRoot.creditorName).arg(cardRoot.xmrDepth);
                            if (!p.ok)
                                return String(p.why || "").indexOf("not-agreed") === 0
                                       ? qsTr("Your share: %1 XMR to %2. The link to pay it appears here once everyone named has agreed.")
                                             .arg(cardRoot.eth(cardRoot.myPart ? cardRoot.myPart.amount : "0")).arg(cardRoot.creditorName)
                                       : qsTr("⚠ No link to pay: %1").arg(cardRoot.xmrDetail(p.why));
                            return qsTr("Pay %1 XMR to %2 from any Monero wallet: Cake, Feather or Basecamp's Monero Wallet. Scan the code or copy the link: it carries the address and the exact amount. Muster never sends Monero.")
                                   .arg(cardRoot.eth(p.amount)).arg(cardRoot.creditorName);
                        }
                        color: !xmrPayBox.pay.ok && String(xmrPayBox.pay.why || "").indexOf("not-agreed") !== 0
                               ? Theme.palette.warning : Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.badgeText
                    }

                    // the link as a QR code, for a wallet on a phone
                    QrCode {
                        objectName: "cardXmrQr"
                        visible: xmrPayBox.linkShown && size > 0
                        text: xmrPayBox.linkShown ? String(xmrPayBox.pay.uri || "") : ""
                        Layout.preferredWidth: 196
                        Layout.preferredHeight: 196
                    }
                    // the link itself, whole: what the code holds
                    TextEdit {
                        objectName: "cardXmrUri"
                        visible: xmrPayBox.linkShown
                        Layout.fillWidth: true
                        readOnly: true
                        selectByMouse: true
                        wrapMode: TextEdit.WrapAnywhere
                        text: String(xmrPayBox.pay.uri || "")
                        color: Theme.palette.text
                        selectionColor: Theme.palette.primary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                    }
                    RowLayout {
                        visible: xmrPayBox.linkShown
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosButton {
                            id: copyLink
                            objectName: "cardXmrCopy"
                            property bool copied: false
                            text: copied ? qsTr("✓ Copied") : qsTr("Copy link")
                            variant: LogosButton.Variant.Secondary
                            onClicked: {
                                clip.text = String(cardRoot.xmrPay ? cardRoot.xmrPay.uri || "" : "");
                                clip.selectAll();
                                clip.copy();
                                copied = true;
                                copiedReset.restart();
                            }
                            TextEdit { id: clip; visible: false; width: 0; height: 0 }
                            Timer { id: copiedReset; interval: 1500; onTriggered: copyLink.copied = false }
                        }
                        Item { Layout.fillWidth: true }
                    }

                    // "I paid": the debtor's claim, with the transaction id if they give one
                    RowLayout {
                        visible: xmrPayBox.linkShown
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosTextField {
                            id: xmrTx
                            objectName: "cardXmrTx"
                            Layout.fillWidth: true
                            placeholderText: qsTr("transaction id (optional)")
                            font.family: Theme.typography.mono
                        }
                        LogosButton {
                            objectName: "cardXmrPaid"
                            readonly property string tx: String(xmrTx.text || "").trim().toLowerCase()
                            enabled: tx.length === 0 || /^[0-9a-f]{64}$/.test(tx)
                            text: qsTr("I paid")
                            onClicked: cardRoot.reportPaid(tx)
                        }
                    }
                    LogosText {
                        visible: xmrPayBox.linkShown
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: String(xmrTx.text || "").trim().length > 0 && !/^[0-9a-fA-F]{64}$/.test(String(xmrTx.text || "").trim())
                              ? qsTr("⚠ A transaction id is 64 hex characters. Leave it empty if you don't have it.")
                              : qsTr("“I paid” tells the room; it doesn't confirm anything. %1's own wallet confirms the payment when it reaches %2 confirmations.")
                                    .arg(cardRoot.creditorName).arg(cardRoot.xmrDepth)
                        color: String(xmrTx.text || "").trim().length > 0 && !/^[0-9a-fA-F]{64}$/.test(String(xmrTx.text || "").trim())
                               ? Theme.palette.warning : Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }
                }

                // on the creditor's client: can my own wallet confirm these payments?
                ColumnLayout {
                    id: xmrWalletBox
                    objectName: "cardXmrWallet"
                    visible: cardRoot.isXmr && cardRoot.iAmCreditor && cardRoot.xmrWallet !== null && !cardRoot.paid
                    Layout.fillWidth: true
                    spacing: Theme.spacing.tiny
                    readonly property var w: cardRoot.xmrWallet || ({})
                    LogosText {
                        objectName: "cardXmrWalletLine"
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: xmrWalletBox.w.ready
                              ? qsTr("Your Monero wallet is open on %1: it confirms each payment once it has %2 confirmations. You can also mark a share received yourself.")
                                    .arg(String(cardRoot.xmr ? cardRoot.xmr.chainLabel || "" : "")).arg(cardRoot.xmrDepth)
                              : String(xmrWalletBox.w.code || "") === "wallet-unread" || String(xmrWalletBox.w.code || "") === "wallet-busy"
                              ? qsTr("Your Monero wallet hasn't answered yet, so nothing is confirmed for now. %1").arg(cardRoot.xmrDetail(xmrWalletBox.w.detail))
                              : qsTr("⚠ Your Monero wallet can't confirm payments now: %1").arg(cardRoot.xmrDetail(xmrWalletBox.w.detail, xmrWalletBox.w.code))
                        color: xmrWalletBox.w.ready ? Theme.palette.textSecondary
                             : String(xmrWalletBox.w.request || "").length > 0 ? Theme.palette.warning : Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }
                    // which wallet Monero Wallet opens (exo-dcc.20): the one the module names;
                    // several that could be it, one button each; none at all, set one up there
                    readonly property var choices: Array.isArray(xmrWalletBox.w.wallets) ? xmrWalletBox.w.wallets : []
                    readonly property bool asks: !xmrWalletBox.w.ready && String(xmrWalletBox.w.request || "") === "monero.wallet.unlock"
                    LogosButton {
                        objectName: "cardXmrOpenWallet"
                        visible: xmrWalletBox.asks && xmrWalletBox.choices.length < 2
                        text: xmrWalletBox.w.noWallet ? qsTr("Set up a wallet in Monero Wallet") : qsTr("Open Monero Wallet")
                        variant: LogosButton.Variant.Secondary
                        onClicked: cardRoot.openMoneroWallet(String(xmrWalletBox.w.wallet || ""))
                    }
                    LogosText {
                        objectName: "cardXmrPickWallet"
                        visible: xmrWalletBox.asks && xmrWalletBox.choices.length > 1
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("Which wallet is this request's? Open it in Monero Wallet:")
                        color: Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.badgeText
                    }
                    Flow {
                        visible: xmrWalletBox.asks && xmrWalletBox.choices.length > 1
                        Layout.fillWidth: true
                        spacing: Theme.spacing.tiny
                        Repeater {
                            model: xmrWalletBox.asks && xmrWalletBox.choices.length > 1 ? xmrWalletBox.choices : []
                            delegate: LogosButton {
                                required property var modelData
                                objectName: "cardXmrOpenWallet_" + String(modelData)
                                text: qsTr("Open %1").arg(String(modelData))
                                variant: LogosButton.Variant.Secondary
                                onClicked: cardRoot.openMoneroWallet(String(modelData))
                            }
                        }
                    }
                    LogosText {
                        objectName: "cardXmrWalletNote"
                        visible: !xmrWalletBox.w.ready && cardRoot.moneroWalletNote.length > 0
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: cardRoot.moneroWalletNote
                        color: Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.badgeText
                    }
                }
            }

            // What a Safe transaction CALLS and HOW (exo-a50.1.4): the data it carries, and
            // a DELEGATECALL named for what it is — the target's code runs AS the Safe and
            // can rewrite its owners (the Bybit vector). Muster refuses to sign one unless
            // this client allowlists the target; the card says so rather than hiding it.
            LogosText {
                Layout.fillWidth: true
                visible: String((cardRoot.card && cardRoot.card.safeData) || "").length > 2
                text: {
                    var d = String((cardRoot.card && cardRoot.card.safeData) || "");
                    var n = Math.max(0, Math.floor((d.length - 2) / 2));
                    return qsTr("with data %1 (%2 bytes)").arg(d.slice(0, 10) + (d.length > 10 ? "…" : "")).arg(n);
                }
                color: Theme.palette.textSecondary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
                wrapMode: Text.WrapAnywhere
            }
            LogosText {
                objectName: "cardDelegatecall"
                Layout.fillWidth: true
                visible: cardRoot.card && Number(cardRoot.card.operation) === 1
                text: qsTr("DELEGATECALL: this runs %1's code as the Safe itself. It can change the Safe's owners, threshold and modules. Muster signs it only if you have allowlisted that target.")
                      .arg(String((cardRoot.card && cardRoot.card.to) || ""))
                color: Theme.palette.error
                font.pixelSize: Theme.typography.secondaryText
                font.weight: Theme.typography.weightMedium
                wrapMode: Text.WordWrap
            }

            // trace this: the effect is a peer-message (someone proposed it into the
            // room). One tap opens the lineage focused on that origin — the card
            // element leads to where it came from, not a separate hunt.
            Item {
                Layout.fillWidth: true
                implicitHeight: effectTrace.implicitHeight
                visible: cardRoot.card && cardRoot.card.provenance
                         && cardRoot.card.provenance.length > 0
                LogosText {
                    id: effectTrace
                    text: qsTr("⌕ trace this")
                    color: Theme.palette.textTertiary
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.badgeText
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: cardRoot.traceClass("peer-message")
                }
            }

            // which rail the room is being asked to agree to
            LogosText {
                Layout.fillWidth: true
                visible: cardRoot.card && cardRoot.card.rail
                wrapMode: Text.WordWrap
                text: String((cardRoot.card && cardRoot.card.rail) || "")
                color: Theme.palette.textSecondary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
            }

            // ── status rail: proposed → collecting → ready → paid ──────────
            // The whole path is drawn from the first card; a step at or before
            // the current state is lit, everything after stays drawn but unlit.
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.spacing.tiny
                spacing: Theme.spacing.tiny

                Repeater {
                    model: [{ k: "proposed", t: qsTr("proposed") },
                            { k: "collecting", t: qsTr("collecting") },
                            { k: "ready", t: qsTr("ready") },
                            { k: "paid", t: qsTr("final") }]

                    delegate: RowLayout {
                        id: step
                        required property var modelData
                        required property int index
                        spacing: 3

                        readonly property bool lit:
                            step.index <= ["proposed", "collecting", "ready", "paid"]
                                            .indexOf(cardRoot.state)

                        Rectangle {
                            implicitWidth: 6
                            implicitHeight: 6
                            radius: 3
                            color: step.lit ? Theme.palette.success
                                            : Theme.palette.borderDefault
                        }

                        LogosText {
                            text: step.modelData.t
                            color: step.lit ? Theme.palette.textSecondary
                                            : Theme.palette.textTertiary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }

                        Item { Layout.preferredWidth: Theme.spacing.small }
                    }
                }
            }

            // ── a LEZ step the chain has not included yet (exo-3c9) ────────
            // A vote-locus approval and the Execute are members' own chain
            // transactions: sent at once, they count only once a block includes them.
            LogosText {
                objectName: "cardChainPending"
                visible: cardRoot.kind === "intent-propose" && !!(cardRoot.card && cardRoot.card.chainPending)
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: cardRoot.card && cardRoot.card.chainPending === "settle"
                      ? qsTr("⏳ Executing on chain — final once a block includes it.")
                      : qsTr("⏳ Your vote is on its way to the chain — it counts once a block includes it.")
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.badgeText
            }

            // ── approval slots ─────────────────────────────────────────────
            // Slots fill as approvals arrive; the empty ones are drawn too,
            // because the shape of what is missing is the information. An
            // approver's initials show when the card carried them.
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.spacing.tiny
                spacing: 4

                Repeater {
                    model: cardRoot.threshold

                    delegate: Rectangle {
                        id: slot
                        required property int index

                        // Filled up to the approvals so far; initials come from
                        // the approvers array when it is long enough.
                        readonly property bool filled: slot.index < cardRoot.approvals
                        // committed approvals fill first; the last `unattested` filled
                        // slots are the pasted ones, drawn as a ring, not a solid dot.
                        readonly property bool pasted: slot.filled
                            && slot.index >= cardRoot.approvals - cardRoot.unattested
                        readonly property var who: cardRoot.card && cardRoot.card.approvers
                            && slot.index < cardRoot.card.approvers.length
                            ? cardRoot.card.approvers[slot.index] : null

                        implicitWidth: 22
                        implicitHeight: 22
                        radius: 11
                        color: slot.filled && !slot.pasted ? Theme.palette.success : "transparent"
                        border.width: slot.pasted ? 2 : (slot.filled ? 0 : 1)
                        border.color: slot.pasted ? Theme.palette.warning : Theme.palette.borderDefault

                        LogosText {
                            anchors.centerIn: parent
                            visible: slot.filled
                            text: slot.who && slot.who.initials
                                ? String(slot.who.initials) : ""
                            color: slot.pasted ? Theme.palette.warning : Theme.palette.background
                            font.pixelSize: Theme.typography.badgeText
                            font.weight: Theme.typography.weightMedium
                        }
                    }
                }

                Item { Layout.fillWidth: true }

                LogosText {
                    text: cardRoot.threshold > 0
                        ? qsTr("%1 of %2").arg(cardRoot.approvals).arg(cardRoot.threshold)
                        : ""
                    color: Theme.palette.textSecondary
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.badgeText
                    font.weight: Theme.typography.weightMedium
                }
            }

            // Who approved, by name ("you" for this member) — the slots' initials, spelled out.
            LogosText {
                objectName: "cardApproverNames"
                readonly property var named: (cardRoot.card && Array.isArray(cardRoot.card.approvers))
                                             ? cardRoot.card.approvers : []
                visible: named.length > 0
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("by %1").arg(named.map(function (a) {
                          var n = String(a.name || "");
                          if (n.length > 0) return n;
                          var w = String(a.who || "");
                          return w.length > 12 ? w.slice(0, 6) + "…" + w.slice(-4) : w; }).join(", "))
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.badgeText
            }

            // Committed vs unattested, in words — only when something was pasted in, so a
            // card whose approvals were all signed in muster stays quiet.
            LogosText {
                objectName: "cardUnattested"
                visible: cardRoot.unattested > 0
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: (cardRoot.approvals - cardRoot.unattested > 0
                        ? qsTr("%1 signed in muster — committed to where every input came from. ")
                              .arg(cardRoot.approvals - cardRoot.unattested)
                        : "")
                    + qsTr("%n signed outside muster and pasted in (ringed) — counted, but committed to nothing beyond the transaction itself.", "", cardRoot.unattested)
                color: Theme.palette.warning
                font.pixelSize: Theme.typography.badgeText
            }

            // trace these: each filled slot is a driver-contribution the driver
            // verified recovers to a configured member. One tap opens the lineage
            // focused on the approvals — who signed, and the guarantee behind each.
            Item {
                Layout.fillWidth: true
                implicitHeight: approvalsTrace.implicitHeight
                visible: cardRoot.approvals > 0 && cardRoot.card
                         && cardRoot.card.provenance && cardRoot.card.provenance.length > 0
                LogosText {
                    id: approvalsTrace
                    text: qsTr("⌕ trace the approvals")
                    color: Theme.palette.textTertiary
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.badgeText
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: cardRoot.traceClass("driver-contribution")
                }
            }

            // Where the rule lives — the FAMILY's own answer (exo-a50.1.6), never a fixed
            // caveat: a Safe's threshold IS enforced by its contract, a room threshold is
            // final in the room. Empty rows (an old module) → nothing claimed at all.
            LogosText {
                Layout.fillWidth: true
                Layout.topMargin: 2
                wrapMode: Text.WordWrap
                visible: text.length > 0
                text: cardRoot.rowText("where")
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.badgeText
            }

            // ── how this account works: the fixed rows (exo-a50.1.6) ─────────
            // The same ten questions for every multisig family, answered by the module
            // from the family profile, each tagged with its credibility and, where
            // someone is relied on or can see, who. Collapsed to one line by default.
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                visible: cardRoot.rows.length > 0
                LogosText {
                    objectName: "cardRowsToggle"
                    text: (cardRoot.rowsOpen ? "▾ " : "▸ ") + qsTr("How this account works")
                    color: Theme.palette.textSecondary
                    font.pixelSize: Theme.typography.badgeText
                    font.weight: Theme.typography.weightMedium
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: cardRoot.rowsOpen = !cardRoot.rowsOpen
                    }
                }
                Repeater {
                    model: cardRoot.rowsOpen ? cardRoot.rows : []
                    delegate: ColumnLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 0
                        LogosText {
                            Layout.fillWidth: true
                            text: String(modelData.label || "")
                                  + (modelData.credibility ? "  ·  " + String(modelData.credibility) : "")
                            color: modelData.credibility === "exposed" ? Theme.palette.error
                                 : modelData.credibility === "motivational" ? Theme.palette.warning
                                 : Theme.palette.textTertiary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }
                        LogosText {
                            Layout.fillWidth: true
                            text: String(modelData.text || "")
                                  + (modelData.party ? "  (" + qsTr("relies on / seen by: %1").arg(String(modelData.party)) + ")" : "")
                            color: Theme.palette.text
                            font.pixelSize: Theme.typography.badgeText
                            wrapMode: Text.WordWrap
                        }
                    }
                }
            }

            // ── verify: dive in to what you'd sign (F-4 / F-5) ──────────────
            // Collapsed, a one-line reassurance; expanded, the safeTxHash this
            // client RE-DERIVED and the domain it is bound to. The effect shown
            // was rebuilt here and compared — a mismatch is refused by the core
            // before an intent ever reaches this fold, so what shows is the honest
            // "matches" state, and the trail is one tap away.
            Rectangle {
                objectName: "verifyBox"
                Layout.fillWidth: true
                Layout.topMargin: Theme.spacing.tiny
                visible: cardRoot.card && cardRoot.card.txhash
                implicitHeight: verifyCol.implicitHeight + 2 * Theme.spacing.small
                radius: Theme.spacing.radiusSmall
                color: Theme.palette.surfaceRecessed
                border.width: 1
                border.color: Theme.palette.success

                // Below the content: LogosText does not accept mouse events, so a
                // tap anywhere on the box falls through to here and toggles it.
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: cardRoot.verifyOpen = !cardRoot.verifyOpen
                }

                ColumnLayout {
                    id: verifyCol
                    anchors.fill: parent
                    anchors.margins: Theme.spacing.small
                    spacing: Theme.spacing.tiny

                    // header: the claim + the caret affordance.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small

                        LogosText {
                            objectName: "verifyHeader"
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: qsTr("✓ your client re-derived this — the exact bytes you'd sign")
                            color: Theme.palette.success
                            font.pixelSize: Theme.typography.secondaryText
                            font.weight: Theme.typography.weightMedium
                        }

                        LogosText {
                            text: cardRoot.verifyOpen ? "−" : "+"
                            color: Theme.palette.success
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.secondaryText
                        }
                    }

                    // body: shown / re-derived / domain — only when opened. Three
                    // explicit rows (the dashboard's re-materialization strip
                    // pattern), each a mono key + a wrapping value.
                    Repeater {
                        model: cardRoot.verifyOpen
                            ? [{ id: "shown",      k: qsTr("shown"),      v: cardRoot.verifyShown() },
                               { id: "re-derived", k: qsTr("re-derived"), v: String((cardRoot.card && cardRoot.card.txhash) || "") },
                               { id: "domain",     k: qsTr("domain"),     v: cardRoot.verifyDomain() }]
                            : []

                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small

                            LogosText {
                                Layout.preferredWidth: 66
                                Layout.alignment: Qt.AlignTop
                                text: modelData.k
                                color: Theme.palette.textTertiary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                            }

                            LogosText {
                                objectName: "verifyVal_" + modelData.id
                                Layout.fillWidth: true
                                wrapMode: Text.WrapAnywhere
                                text: modelData.v
                                color: Theme.palette.textSecondary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.secondaryText
                            }
                        }
                    }
                }
            }

            // ── provenance: how do I know this? (invariant 10) ──────────────
            // The deepest dive-in: every input that put this decision in front of
            // you, by class + where it came from + why it can be trusted. Neutral
            // ground (not the verify box's green) — this is lineage, not a verdict.
            Rectangle {
                objectName: "provenanceBox"
                Layout.fillWidth: true
                Layout.topMargin: Theme.spacing.tiny
                visible: cardRoot.card && cardRoot.card.provenance
                         && cardRoot.card.provenance.length > 0
                implicitHeight: provCol.implicitHeight + 2 * Theme.spacing.small
                radius: Theme.spacing.radiusSmall
                color: Theme.palette.surfaceRecessed
                border.width: 1
                border.color: Theme.palette.borderSubtle

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    // Opened from its own header = no element focus: show the whole
                    // lineage evenly. A "trace this" tap sets focus before opening.
                    onClicked: {
                        cardRoot.provOpen = !cardRoot.provOpen;
                        cardRoot.provFocus = "";
                    }
                }

                ColumnLayout {
                    id: provCol
                    anchors.fill: parent
                    anchors.margins: Theme.spacing.small
                    spacing: Theme.spacing.tiny

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small

                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: qsTr("How do I know this? — %1 in the lineage")
                                .arg(cardRoot.card && cardRoot.card.provenance
                                     ? cardRoot.card.provenance.length : 0)
                            color: Theme.palette.textSecondary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                            font.weight: Theme.typography.weightMedium
                        }

                        LogosText {
                            text: cardRoot.provOpen ? "−" : "+"
                            color: Theme.palette.textSecondary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.secondaryText
                        }
                    }

                    // Collapsed glance: who is behind this decision (names where known).
                    LogosText {
                        readonly property string who:
                            cardRoot.provWho(cardRoot.card ? cardRoot.card.provenance : [])
                        visible: !cardRoot.provOpen && who.length > 0
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("by %1").arg(who)
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }

                    // intro — only when open.
                    LogosText {
                        visible: cardRoot.provOpen
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("Where each piece of this came from. Nothing here is "
                                 + "unaccountable — an input the client couldn't trace would "
                                 + "have been refused before signing.")
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }

                    // one entry per input in the lineage.
                    Repeater {
                        model: (cardRoot.provOpen && cardRoot.card && cardRoot.card.provenance)
                               ? cardRoot.card.provenance : []

                        // A "trace this" tap focuses one class: its entries are lit
                        // with an accent bar, the rest dimmed, so the tapped card
                        // element leads the eye to exactly its own lineage.
                        delegate: RowLayout {
                            id: provEntry
                            required property var modelData
                            readonly property bool focused: cardRoot.provFocus.length > 0
                                && String((modelData && modelData["class"]) || "") === cardRoot.provFocus
                            readonly property bool dimmed: cardRoot.provFocus.length > 0 && !focused
                            Layout.fillWidth: true
                            Layout.topMargin: 2
                            spacing: Theme.spacing.tiny
                            opacity: dimmed ? 0.4 : 1.0

                            Rectangle {
                                Layout.fillHeight: true
                                Layout.preferredWidth: 2
                                radius: 1
                                visible: provEntry.focused
                                color: Theme.palette.textSecondary
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 1

                                LogosText {
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    // WHAT this input is, and its concrete content — the
                                    // proposal shows the effect it carried ("pay 42 to
                                    // 0x…"), an approval its round; so you investigate the
                                    // actual piece of information, not a generic label.
                                    text: {
                                        var lbl = "[" + String((modelData && modelData["class"]) || "") + "]  "
                                                + String((modelData && modelData.what) || "");
                                        var d = String((modelData && modelData.detail) || "");
                                        return d.length > 0 ? lbl + "  —  " + d : lbl;
                                    }
                                    color: Theme.palette.text
                                    font.family: Theme.typography.mono
                                    font.pixelSize: Theme.typography.badgeText
                                    font.weight: Theme.typography.weightMedium
                                }

                                LogosText {
                                    Layout.fillWidth: true
                                    Layout.leftMargin: Theme.spacing.small
                                    wrapMode: Text.WrapAnywhere
                                    text: cardRoot.provTrust(modelData)
                                    color: Theme.palette.textTertiary
                                    font.family: Theme.typography.mono
                                    font.pixelSize: Theme.typography.badgeText
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── send-receipt ({amount, denom, rail, tx, discloses}) ────────────
        // The one moment something leaves the room, on the recessed ground.
        // Names the effect, then lists what the chain actually got.
        ColumnLayout {
            visible: cardRoot.kind === "send-receipt"
            Layout.fillWidth: true
            spacing: Theme.spacing.tiny

            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: (String((cardRoot.card && cardRoot.card.amount) || "")
                    + " " + String((cardRoot.card && cardRoot.card.denom) || "")).trim()
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.primaryText
                font.weight: Theme.typography.weightMedium
            }

            LogosText {
                Layout.fillWidth: true
                visible: cardRoot.card && cardRoot.card.rail
                text: String((cardRoot.card && cardRoot.card.rail) || "")
                color: Theme.palette.textSecondary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
            }

            // ── what left the room ─────────────────────────────────────────
            // Read straight off the receipt's own `discloses`. A withheld
            // field is the good outcome, so it takes the success accent; a
            // disclosed one is stated plainly. An absent `discloses` says so
            // rather than guessing what a rail leaked.
            LogosText {
                Layout.fillWidth: true
                Layout.topMargin: Theme.spacing.tiny
                text: qsTr("WHAT LEFT THE ROOM")
                color: Theme.palette.textTertiary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
                font.weight: Theme.typography.weightMedium
            }

            Repeater {
                model: {
                    var d = cardRoot.card && cardRoot.card.discloses
                        ? cardRoot.card.discloses : {};
                    return [
                        { k: qsTr("amount"),
                          v: d.amount ? String((cardRoot.card && cardRoot.card.amount) || "")
                                      : qsTr("not disclosed"),
                          withheld: !d.amount },
                        { k: qsTr("who paid"),
                          v: d.payer ? qsTr("on the record") : qsTr("not disclosed"),
                          withheld: !d.payer },
                        { k: qsTr("who was paid"),
                          v: d.payee ? qsTr("on the record") : qsTr("not disclosed"),
                          withheld: !d.payee }];
                }

                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosText {
                        text: modelData.k
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                    }

                    Item { Layout.fillWidth: true }

                    LogosText {
                        text: modelData.v
                        color: modelData.withheld
                            ? Theme.palette.success : Theme.palette.textSecondary
                        horizontalAlignment: Text.AlignRight
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }
                }
            }

            // The tx id, last and quietest — the thing you would take to an
            // explorer, and the least interesting fact on the card.
            LogosText {
                Layout.fillWidth: true
                visible: cardRoot.card && cardRoot.card.tx
                wrapMode: Text.WrapAnywhere
                elide: Text.ElideRight
                text: String((cardRoot.card && cardRoot.card.tx) || "")
                color: Theme.palette.textTertiary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
            }
        }

        // ── what this needs: the five questions + YOUR readiness (exo-002.3) ──
        // What will it do (the card above), what is needed (each requirement met /
        // missing / unknown, with the remedy), what will it touch, what will happen
        // (the full disclosure — the store node included, FS-9), how we agree. All
        // from coordinate_readiness; unknown and undeclared are shown as such.
        LogosText {
            objectName: "cardDeclined"
            visible: cardRoot.kind === "intent-propose" && cardRoot.schemaKnown && cardRoot.declines > 0
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: qsTr("%1 declined: %2").arg(cardRoot.declines).arg(
                      ((cardRoot.card && Array.isArray(cardRoot.card.declinerNames) && cardRoot.card.declinerNames.length > 0)
                         ? cardRoot.card.declinerNames : cardRoot.decliners.map(function (d) { return { who: d, name: "" }; }))
                      .map(function (d) {
                          var n = String(d.name || "");
                          if (n.length > 0) return n;
                          var x = String(d.who || ""); return x.length > 12 ? x.slice(0, 6) + "…" + x.slice(-4) : x; }).join(", "))
            color: Theme.palette.warning
            font.pixelSize: Theme.typography.badgeText
        }

        Rectangle {
            objectName: "needsBox"
            visible: cardRoot.kind === "intent-propose" && cardRoot.schemaKnown
            Layout.fillWidth: true
            Layout.topMargin: Theme.spacing.tiny
            implicitHeight: needsCol.implicitHeight + 2 * Theme.spacing.small
            radius: Theme.spacing.radiusSmall
            color: Theme.palette.surfaceRecessed
            border.width: 1
            border.color: (cardRoot.readiness && cardRoot.readiness.ready) ? Theme.palette.success
                        : (cardRoot.readiness && cardRoot.readiness.declared === false) ? Theme.palette.warning
                        : Theme.palette.borderSubtle

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    cardRoot.needsOpen = !cardRoot.needsOpen;
                    if (cardRoot.needsOpen) cardRoot.installNow = Date.now();
                    if (cardRoot.needsOpen && !cardRoot.readiness) cardRoot.needs();
                    // every reopening reads readiness again: a module may have been
                    // installed or started since it was last read (exo-dcc.10)
                    else if (cardRoot.needsOpen) cardRoot.recheckReadiness();
                }
            }

            ColumnLayout {
                id: needsCol
                anchors.fill: parent
                anchors.margins: Theme.spacing.small
                spacing: Theme.spacing.tiny

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    LogosText {
                        objectName: "needsHeader"
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: cardRoot.readiness ? qsTr("What this needs — %1").arg(cardRoot.readinessSummary())
                                                 : qsTr("What this needs")
                        color: (cardRoot.readiness && cardRoot.readiness.ready) ? Theme.palette.success : Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.secondaryText
                        font.weight: Theme.typography.weightMedium
                    }
                    LogosText {
                        text: cardRoot.needsOpen ? "−" : "+"
                        color: Theme.palette.textSecondary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.secondaryText
                    }
                }

                LogosText {
                    visible: cardRoot.needsOpen && !cardRoot.readiness
                    text: qsTr("checking with the module…")
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.badgeText
                }

                // needs: one row per requirement — status, what, detail, remedy.
                Repeater {
                    model: (cardRoot.needsOpen && cardRoot.readiness && cardRoot.readiness.items) ? cardRoot.readiness.items : []
                    delegate: ColumnLayout {
                        id: needRow
                        required property var modelData
                        // a module need (exo-dcc.10): the package to ask Package Manager
                        // for, and what that request answered
                        readonly property string pkg: cardRoot.installPkg(needRow.modelData)
                        readonly property var req: cardRoot.installReq(needRow.pkg)
                        readonly property string note: needRow.modelData.status === "met" ? ""
                                                       : cardRoot.installNote(needRow.pkg, needRow.modelData)
                        Layout.fillWidth: true
                        spacing: 0
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            LogosText {
                                objectName: "needStatus_" + String(modelData.kind) + "_" + String(modelData.name)
                                text: modelData.status === "met" ? "✓" : modelData.status === "missing" ? "✗" : "?"
                                color: modelData.status === "met" ? Theme.palette.success
                                     : modelData.status === "missing" ? Theme.palette.warning : Theme.palette.textTertiary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.secondaryText
                            }
                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: String(modelData.kind) + ": " + String(modelData.name)
                                    + (modelData.party === "contributor" ? qsTr(" (each signer)")
                                       : modelData.party === "payer" ? qsTr(" (each person who pays their part)") : "")
                                    + (modelData.detail ? " — " + String(modelData.detail) : "")
                                color: Theme.palette.text
                                font.pixelSize: Theme.typography.badgeText
                            }
                        }
                        RowLayout {
                            visible: !!modelData.remedy
                            Layout.fillWidth: true
                            Layout.leftMargin: Theme.spacing.medium
                            spacing: Theme.spacing.small
                            // module remedies are whole instructions now ("install … from
                            // Basecamp's Package Manager", "start …"), so every row reads
                            // "To fix:"; the Install button below is the one-click form
                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: qsTr("To fix: ") + String(modelData.remedy || "")
                                color: Theme.palette.textSecondary
                                font.pixelSize: Theme.typography.badgeText
                            }
                            // A LEZ account is provisioned in the LEZ Wallet App, not
                            // Settings (exo-44b). Muster only detects + points; the
                            // automatic hand-off (logos.request) rides the app-to-app
                            // broker (L4), so today this is an honest prompt, not a button
                            // that would open the wrong place.
                            LogosText {
                                visible: modelData.kind === "infra" && modelData.name === "lez-account"
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: qsTr("↳ Open the LEZ Wallet App to set up a funded account, then reopen this.")
                                color: Theme.palette.textTertiary
                                font.pixelSize: Theme.typography.badgeText
                            }
                            LogosButton {
                                objectName: "needRemedy_" + String(modelData.kind)
                                visible: ((modelData.kind === "infra" && modelData.name !== "lez-account")
                                          || modelData.kind === "environment")
                                         && String(modelData.request || "").length === 0
                                text: qsTr("Open settings")
                                variant: LogosButton.Variant.Secondary
                                onClicked: cardRoot.openSettings()
                            }
                            // a Monero wallet that is closed or on another network (exo-dcc.5):
                            // Monero Wallet opens it; muster never holds its password
                            LogosButton {
                                objectName: "needRequest_" + String(modelData.name)
                                visible: String(modelData.request || "") === "monero.wallet.unlock"
                                         && modelData.status !== "met"
                                text: qsTr("Open Monero Wallet")
                                variant: LogosButton.Variant.Secondary
                                onClicked: cardRoot.openMoneroWallet(String(modelData.wallet || ""))
                            }
                        }
                        // A module that is not installed (exo-dcc.10): ask Basecamp's
                        // Package Manager to open on the package the module names. The
                        // person confirms the install there; Muster installs nothing. An
                        // ok answer means Package Manager is open, not that it installed,
                        // so the card re-reads readiness until the module runs.
                        ColumnLayout {
                            visible: needRow.modelData.kind === "module" && needRow.modelData.status !== "met"
                            Layout.fillWidth: true
                            Layout.leftMargin: Theme.spacing.medium
                            spacing: Theme.spacing.tiny
                            LogosButton {
                                objectName: "needInstall_" + String(needRow.modelData.name)
                                visible: cardRoot.canInstall(needRow.modelData)
                                enabled: !(needRow.req && needRow.req.state === "asking")
                                text: qsTr("Install %1").arg(String(needRow.modelData.install || ""))
                                variant: LogosButton.Variant.Secondary
                                onClicked: cardRoot.askInstall(needRow.modelData)
                            }
                            LogosText {
                                objectName: "installStatus_" + needRow.pkg
                                visible: needRow.note.length > 0
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: needRow.note
                                color: (needRow.req && (needRow.req.state === "open" || needRow.req.state === "asking"))
                                       ? Theme.palette.textSecondary : Theme.palette.warning
                                font.pixelSize: Theme.typography.badgeText
                            }
                            // not in any enabled catalogue: show the package in Package
                            // Manager, where the catalogues are
                            LogosButton {
                                objectName: "installShow_" + needRow.pkg
                                visible: !!(needRow.req && needRow.req.state === "failed")
                                text: qsTr("Open Package Manager")
                                variant: LogosButton.Variant.Secondary
                                onClicked: cardRoot.showPackage(needRow.pkg)
                            }
                            LogosText {
                                visible: !!(needRow.req && needRow.req.state === "failed" && needRow.req.showError)
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                // "failed": Package Manager opened, but found no such package
                                text: String((needRow.req && needRow.req.showError) || "") === "failed"
                                      ? qsTr("Package Manager opened, but could not find %1. Check its catalogues.").arg(needRow.pkg)
                                      : qsTr("Package Manager could not be opened (%1). Open it from Basecamp.")
                                        .arg(String((needRow.req && needRow.req.showError) || ""))
                                color: Theme.palette.warning
                                font.pixelSize: Theme.typography.badgeText
                            }
                            // read readiness again on demand: the module may have been
                            // installed or started since (and the re-read window is over)
                            LogosButton {
                                objectName: "needRecheck_" + String(needRow.modelData.name)
                                visible: !cardRoot.installAwaited
                                text: qsTr("Check again")
                                variant: LogosButton.Variant.Secondary
                                onClicked: cardRoot.recheckReadiness()
                            }
                        }
                    }
                }

                // ── From you (exo-45e K6): which of MY holdings fill the slots this asks
                // of me — graded about me only. Each candidate shows its public face, its
                // F-10 grade, and what choosing it discloses; a pick shares the PUBLIC face.
                LogosText {
                    visible: cardRoot.showFromYou && cardRoot.needsOpen && cardRoot.shareableOffers.length > 0
                    text: qsTr("From you:")
                    color: Theme.palette.textSecondary
                    font.pixelSize: Theme.typography.badgeText
                    font.weight: Theme.typography.weightMedium
                }
                Repeater {
                    model: (cardRoot.showFromYou && cardRoot.needsOpen) ? cardRoot.shareableOffers : []
                    delegate: ColumnLayout {
                        id: offerSlot
                        required property var modelData
                        readonly property string reqName: (modelData.requirement && modelData.requirement.name)
                                                          ? String(modelData.requirement.name) : ""
                        Layout.fillWidth: true
                        Layout.leftMargin: Theme.spacing.medium
                        spacing: 0
                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: {
                                var r = offerSlot.modelData.requirement || ({});
                                var what = String(r.field || r.name || "");
                                if (offerSlot.modelData.status === "unsatisfiable") return "✗ " + what + qsTr(" — nothing you hold fits this");
                                if (offerSlot.modelData.status === "unknown") return "? " + what + qsTr(" — can't tell yet");
                                return what + qsTr(" — pick what to share:");
                            }
                            color: offerSlot.modelData.status === "satisfiable" ? Theme.palette.text : Theme.palette.warning
                            font.pixelSize: Theme.typography.badgeText
                        }
                        Repeater {
                            model: offerSlot.modelData.candidates || []
                            delegate: RowLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.leftMargin: Theme.spacing.medium
                                spacing: Theme.spacing.small
                                LogosText {
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    text: {
                                        var d = (modelData.discloses || []).map(function (x) {
                                            return String(x.field) + "→" + String(x.to); }).join(", ");
                                        return String(modelData["public"]) + "  (" + String(modelData.grade) + ")"
                                             + (d.length > 0 ? "  ·  " + qsTr("discloses ") + d : "");
                                    }
                                    color: Theme.palette.textSecondary
                                    font.pixelSize: Theme.typography.badgeText
                                }
                                LogosButton {
                                    objectName: "shareCandidate"
                                    text: qsTr("Share")
                                    variant: LogosButton.Variant.Secondary
                                    onClicked: cardRoot.shareMaterial(offerSlot.reqName, String(modelData["public"]))
                                }
                            }
                        }
                    }
                }

                // touches
                LogosText {
                    visible: cardRoot.needsOpen && cardRoot.readiness && cardRoot.readiness.manifest
                             && cardRoot.readiness.manifest.touches && cardRoot.readiness.manifest.touches.length > 0
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: visible ? qsTr("Touches: ") + cardRoot.readiness.manifest.touches.map(function (t) {
                              return String(t.target) + " (" + String(t.mode) + ")"; }).join(", ") : ""
                    color: Theme.palette.textSecondary
                    font.pixelSize: Theme.typography.badgeText
                }

                // what will happen: the disclosure, grouped by observer, outside-the-room included
                LogosText {
                    visible: cardRoot.needsOpen && cardRoot.readiness && cardRoot.readiness.declared !== false
                    text: qsTr("Who will see what:")
                    color: Theme.palette.textSecondary
                    font.pixelSize: Theme.typography.badgeText
                    font.weight: Theme.typography.weightMedium
                }
                Repeater {
                    model: cardRoot.needsOpen ? cardRoot.disclosureGroups() : []
                    delegate: LogosText {
                        required property var modelData
                        objectName: "disclose_" + String(modelData.to)
                        Layout.fillWidth: true
                        Layout.leftMargin: Theme.spacing.medium
                        wrapMode: Text.WordWrap
                        text: String(modelData.label) + ": " + String(modelData.fields)
                        color: modelData.to === "room-member" ? Theme.palette.textSecondary : Theme.palette.warning
                        font.pixelSize: Theme.typography.badgeText
                    }
                }

                // how we agree
                LogosText {
                    visible: cardRoot.needsOpen && cardRoot.agreementLine().length > 0
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: qsTr("Agreement: ") + cardRoot.agreementLine()
                    color: Theme.palette.textSecondary
                    font.pixelSize: Theme.typography.badgeText
                }
            }
        }

        // ── actions ────────────────────────────────────────────────────────
        // address-request: the reader answers with an address.
        LogosButton {
            objectName: "cardShareAddress"
            // only to someone asked, and only until they have answered (exo-8e2)
            visible: cardRoot.kind === "address-request" && cardRoot.askedOfMe && !cardRoot.answeredByMe
            Layout.fillWidth: true
            text: String((cardRoot.card && cardRoot.card.asset) || "ETH") === "BTC" ? qsTr("Share my Bitcoin address")
                  : String((cardRoot.card && cardRoot.card.asset) || "ETH") === "XMR" ? qsTr("Share my Monero address")
                  : qsTr("Share an address")
            onClicked: cardRoot.shareAddress()
        }

        // intent-propose: approve while it still needs you. Settling a ready
        // Safe intent is the room's "Settle on-chain" affordance (Room.qml's
        // ready box), driven by the verified fold — not a card button. The old
        // "Pay it"/"Drop it" buttons had no wired path (no coordinate_drop, and
        // paying flows through propose→approve→settle), so they only ever fired
        // signals nothing listened to; removed rather than leave dead controls.
        LogosButton {
            objectName: "cardApprove"
            visible: cardRoot.kind === "intent-propose" && cardRoot.schemaKnown
                && !(cardRoot.card && cardRoot.card.approvedByMe)
                && !cardRoot.ready
                // a split: only who it names agrees — each debtor, and the creditor to payTo
                // being theirs (exo-770), never to an address this client does not hold
                && (!cardRoot.isSplit || cardRoot.iAmDebtor || (cardRoot.iAmCreditor && (cardRoot.payToMine || cardRoot.payToMineUnknown)))
                && (!cardRoot.isSettleUp || !!cardRoot.settleUp.iAmParty)
                && !cardRoot.vouchedNotMine    // never vouch for an address this client does not hold
                && !cardRoot.splitExpired      // past its expiry an agreement is refused (inv 2)
            Layout.fillWidth: true
            text: cardRoot.isSettleUp ? qsTr("Agree to settle up")
                : !cardRoot.isSplit ? qsTr("Approve")
                : cardRoot.iAmDebtor ? qsTr("Agree to my share")
                : qsTr("Agree — I paid, and %1 is mine").arg(cardRoot.shortPayTo(String((cardRoot.split && cardRoot.split.payTo) || "")))
            onClicked: cardRoot.approve()
        }

        // Deny: decline to take part while it still needs signers. Informational —
        // the threshold is unchanged; the room sees who is out. One per member; folds once.
        LogosButton {
            objectName: "cardDeny"
            visible: cardRoot.kind === "intent-propose" && cardRoot.schemaKnown
                && !(cardRoot.card && cardRoot.card.approvedByMe)
                && !cardRoot.declinedByMe
                && !cardRoot.ready
                && (!cardRoot.isSplit || cardRoot.iAmDebtor || cardRoot.iAmCreditor)
            Layout.fillWidth: true
            text: qsTr("Deny")
            variant: LogosButton.Variant.Secondary
            onClicked: cardRoot.deny()
        }

        // A settle-up (exo-3c6): once every party agreed, each pays their own net payments —
        // derived from the agreed settle-up, one at a time; the recipient's client confirms.
        LogosButton {
            objectName: "cardPaySettle"
            visible: cardRoot.kind === "intent-propose" && cardRoot.isSettleUp && cardRoot.ready
                && !cardRoot.settleUp.expired
                && cardRoot.myTransfer !== null
            Layout.fillWidth: true
            text: cardRoot.myTransfer
                  ? qsTr("Pay %1 %2 to %3").arg(cardRoot.eth(cardRoot.myTransfer.amount)).arg(cardRoot.unit)
                        .arg(String(cardRoot.myTransfer.toName || "").length > 0 ? cardRoot.myTransfer.toName
                             : String(cardRoot.myTransfer.to).slice(0, 10) + "…")
                  : ""
            onClicked: cardRoot.settlePart()
        }

        // A split (exo-a90): once everyone named has agreed, each pays their OWN share from
        // their own wallet. The module derives the payment from the agreed split — this
        // button carries no amount and no address.
        LogosButton {
            objectName: "cardPayShare"
            visible: cardRoot.kind === "intent-propose" && cardRoot.isSplit && cardRoot.iAmDebtor && !cardRoot.isXmr
                && cardRoot.ready && !cardRoot.paid && !cardRoot.splitExpired
                && cardRoot.myPart !== null && !cardRoot.myPart.settled && !cardRoot.myPart.paying
                && !cardRoot.myPart.covered
            Layout.fillWidth: true
            text: cardRoot.myPart ? qsTr("Pay my share — %1 %2").arg(cardRoot.eth(cardRoot.myPart.amount)).arg(cardRoot.unit)
                                  : qsTr("Pay my share")
            onClicked: cardRoot.settlePart()
        }
        // Past its expiry (exo-a90.15) no share of a split is paid. Say so, and — while a share
        // is unpaid and not already being settled — offer to renew those shares: a settle-up
        // of this split, which everyone they name agrees to again, under a fresh expiry.
        LogosText {
            objectName: "cardSplitExpired"
            visible: cardRoot.kind === "intent-propose" && cardRoot.isSplit && cardRoot.splitExpired
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: !cardRoot.split ? ""
                  : !cardRoot.ready ? qsTr("Expired before everyone agreed. Propose it again with a different note to start over.")
                  : cardRoot.split.renewalPending
                  ? qsTr("Expired: no share of it can be paid now. A renewal of its unpaid shares is waiting below for everyone it names to agree.")
                  : cardRoot.split.renewable
                  ? qsTr("Expired: no share of it can be paid now. Renewing asks everyone who still owes a share to agree again, under a new expiry; once they pay, this split is settled too.")
                  : cardRoot.split.private ? qsTr("Expired: no share of it can be paid now. A private split is not renewed — propose it again.")
                  : qsTr("Expired: no share of it can be paid now. Its unpaid shares are already in a renewal or a settle-up.")
            color: Theme.palette.warning
            font.pixelSize: Theme.typography.badgeText
        }
        LogosButton {
            objectName: "cardRenewSplit"
            visible: cardRoot.kind === "intent-propose" && cardRoot.isSplit && cardRoot.splitExpired
                     && cardRoot.ready && !!cardRoot.split.renewable && (cardRoot.iAmDebtor || cardRoot.iAmCreditor)
            Layout.fillWidth: true
            text: qsTr("Renew the unpaid shares")
            onClicked: cardRoot.renewSplit()
        }
        LogosText {
            objectName: "cardSplitNote"
            visible: cardRoot.isSplit && cardRoot.splitNote.length > 0
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: cardRoot.splitNote
            color: cardRoot.splitNote.indexOf("⚠") === 0 ? Theme.palette.warning : Theme.palette.textSecondary
            font.pixelSize: Theme.typography.badgeText
        }

        // Download audit trail (exo-403): one self-verifying file of everything this
        // intent's approvals cover, plus a readable report generated from it.
        LogosButton {
            objectName: "cardDownloadAudit"
            visible: cardRoot.kind === "intent-propose" && cardRoot.schemaKnown
            Layout.fillWidth: true
            text: qsTr("Download audit trail")
            variant: LogosButton.Variant.Secondary
            onClicked: cardRoot.downloadAudit()
        }
        LogosText {
            objectName: "cardAuditStatus"
            visible: cardRoot.auditStatus.length > 0
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: cardRoot.auditStatus
            color: Theme.palette.textSecondary
            font.pixelSize: Theme.typography.badgeText
        }
    }
}
