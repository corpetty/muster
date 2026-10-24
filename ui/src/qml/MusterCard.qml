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
// An unknown kind renders nothing (implicitHeight 0, visible false), and the
// thread, which reads `known`, shows the message as plain text instead. A voice
// note is not one of these kinds: no message body may carry one, and the thread
// draws it from its row's own field (CardVoiceNote, docs/design/voice-notes.md §7).
// Every field is guarded, because a card is peer JSON: a missing field is normal,
// never an error.
//
// NB (ADR-011): nix build does not evaluate QML; a bad type name here blanks
// the whole view invisibly. Restricted to Theme keys and the Logos.Controls
// types Room.qml / Walkthrough.qml already prove — LogosText, LogosButton.
Rectangle {
    id: cardRoot
    // The card's pieces (CardProposal, CardNeeds, …) each take this card as their
    // `cardRoot`; passed by this name, since `cardRoot: cardRoot` would bind to itself.
    readonly property Item cardItem: cardRoot
    objectName: "musterCard"

    // The parsed card object: { kind, ... }. Never assume more than `kind`.
    property var card

    // Compact by default (exo-720.10, docs/design/ui-modernization.md U6): a proposal shows
    // what it does, where it stands, its approvals and anything to heed. Details shows the
    // explanations: the status rail, how the account works, what this needs, the verify box
    // and the lineage. The reader's own toggle; opening any of those opens Details too.
    property bool detailsOpen: false
    onVerifyOpenChanged: if (verifyOpen) detailsOpen = true
    onProvOpenChanged: if (provOpen) detailsOpen = true
    onRowsOpenChanged: if (rowsOpen) detailsOpen = true

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
        if (grade === "committed") parts.push(qsTr("signed in Muster, tied to where each input came from"));
        else if (grade === "unattested") parts.push(qsTr("signed outside Muster and pasted in"));
        if (why.length > 0) parts.push(why);
        if (pos !== "") parts.push(qsTr("log #%1").arg(pos));
        return parts.join("  ·  ");
    }

    // A one-line "who is behind this" for the collapsed lineage header — the distinct
    // names (aliases where known) that contributed, so you see the people behind a
    // decision at a glance before diving into the full per-piece lineage.
    // a key as the card already names it: an approver's or a proposer's name, or ""
    function nameOnCard(key) {
        var k = MusterStyle.personKey(key);
        if (k.length === 0) return "";
        var lists = [(cardRoot.card && cardRoot.card.approvers) || [], (cardRoot.card && cardRoot.card.proposedBy) || []];
        for (var l = 0; l < lists.length; ++l)
            for (var i = 0; i < lists[l].length; ++i)
                if (MusterStyle.personKey(lists[l][i].who) === k)
                    return lists[l][i].mine ? qsTr("you") : String(lists[l][i].name || "");
        return "";
    }
    function provWho(prov) {
        if (!prov || prov.length === 0) return "";
        var names = [];
        for (var i = 0; i < prov.length; i++) {
            var it = prov[i];
            var who = String((it && it.alias) || "");
            if (who.length === 0) {
                // the card's own people first ("you", "Bob"), then a short id, never "ed:"
                var a = String((it && it.account) || "");
                who = cardRoot.nameOnCard(a);
                if (who.length === 0 && a.length > 0) who = MusterStyle.personKey(a).substring(0, 6) + "…";
            }
            if (who.length > 0 && names.indexOf(who) === -1) names.push(who);
        }
        return names.join(", ");
    }

    // The verify rows, built off `card` (guarded — a missing field is normal).
    // An amount in base units, read the way a person reads it: wei as ETH, sat as BTC. The
    // exact base units stay in Details ("checked"); this is the words on the card.
    function amountText(amt, den) {
        var a = String(amt || ""), d = String(den || "");
        if (a.length === 0 || !/^[0-9]+$/.test(a)) return (a + " " + d).trim();
        var dec = d === "wei" ? 18 : d === "sat" ? 8 : -1;
        if (dec < 0) return (a + " " + d).trim();
        var s = a.replace(/^0+/, "");
        if (s.length === 0) s = "0";
        while (s.length <= dec) s = "0" + s;
        var whole = s.slice(0, s.length - dec), frac = s.slice(s.length - dec).replace(/0+$/, "");
        return (frac.length > 0 ? whole + "." + frac : whole) + " " + (d === "wei" ? "ETH" : "BTC");
    }
    function verifyShown() {
        var stmt = String((cardRoot.card && cardRoot.card.statement) || "");
        if (stmt.length > 0)
            return "“" + stmt + "”";
        // a split shows what its card says: the total, the memo, and where shares are paid
        if (cardRoot.split) {
            var memo = String(cardRoot.split.memo || "");
            var payTo = String(cardRoot.split.payTo || "");
            return (cardRoot.eth(cardRoot.split.total) + " " + cardRoot.unit
                    + (memo.length > 0 ? " · " + memo : "")
                    + (payTo.length > 0 ? "  →  " + cardRoot.shortPayTo(payTo) : "")).trim();
        }
        var amt = String((cardRoot.card && cardRoot.card.amount) || "");
        var den = String((cardRoot.card && cardRoot.card.denom) || "");
        var to = String((cardRoot.card && cardRoot.card.to) || "");
        var lead = cardRoot.amountText(amt, den);
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
    // Decline to take part. Final (exo-720): a decliner's approval counts for nothing, and a
    // proposal too many of its signers declined is closed (state "declined").
    signal deny()
    // Save this intent's signature-audit file + report (exo-403).
    signal downloadAudit()
    // "Who sees this?" (exo-720.10): the room opens its Privacy tab — who can see what
    signal whoSees()
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
    // closed by declines: too many of those who could approve declined (the module's fold)
    readonly property bool isDeclined: !!(cardRoot.card && cardRoot.card.state === "declined")

    // The disclosure rows grouped by observer class, in a fixed honest order — the
    // room first, then everything OUTSIDE the boundary (store node, RPC, chain, module).
    function disclosureGroups() {
        var r = cardRoot.readiness;
        if (!r || !r.manifest || !r.manifest.discloses) return [];
        var order = ["room-member", "store-node", "rpc-provider", "chain-observer", "target-module",
                     "storage-peer", "storage-dht"];
        var label = { "room-member": qsTr("the room"), "store-node": qsTr("the store node"),
                      "rpc-provider": qsTr("your RPC provider"), "chain-observer": qsTr("anyone reading the chain"),
                      "target-module": qsTr("the module it calls"),
                      "storage-peer": qsTr("storage nodes that serve or fetch it"),
                      "storage-dht": qsTr("anyone reading the storage network") };
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
        if (!r.declared) return qsTr("this kind of proposal hasn't said what it needs, so nothing is guessed");
        if (r.ready) return qsTr("✓ you have everything this needs");
        var missing = 0;
        for (var i = 0; i < (r.items || []).length; ++i) if (r.items[i].status === "missing") ++missing;
        var parts = [];
        if (missing > 0) parts.push(qsTr("%1 missing").arg(missing));
        if (Number(r.unknown || 0) > 0) parts.push(qsTr("%1 unknown").arg(r.unknown));
        return parts.join(" · ");
    }
    // readiness was read and names something missing, or could not be read: the card keeps
    // "What this needs" on its face with Details closed (U-8)
    readonly property bool needsBlocked: {
        var r = cardRoot.readiness;
        if (!r) return false;
        if (r.error) return true;
        if (!r.declared || r.ready) return false;
        var items = r.items || [];
        for (var i = 0; i < items.length; ++i) if (items[i].status === "missing") return true;
        return false;
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
    // pay from Monero Wallet: its Send filled in with this address and amount
    // (monero.wallet.send), or, a wallet without that, brought up on its own view
    // (basecamp.apps.launch) — never its accounts or Settings, which monero.accounts.manage opens
    signal presentMoneroWallet(string address, string amount)
    property bool moneroWalletFilled: false   // the last pay request filled Monero Wallet's Send
    property string moneroWalletNote: ""
    readonly property var xmr: (cardRoot.split && cardRoot.split.xmr) ? cardRoot.split.xmr : null
    // A Monero multisig spend's progress (ADR-020): {intentId, state, signers, synced, signed,
    // txids, last, wallet}, null for any other intent. Room.qml looks it up by intent id.
    readonly property var xmrMsig: (cardRoot.card && cardRoot.card.xmrMsig) ? cardRoot.card.xmrMsig : null
    readonly property bool isXmr: cardRoot.xmr !== null
    // MY share's link, if I owe one: {part, ok, uri, amount, payTo, why, reported, confirmed}
    readonly property var xmrPay: (cardRoot.xmr && cardRoot.xmr.payment) ? cardRoot.xmr.payment : null
    // on the creditor's client: whether their open wallet can confirm {ready, detail, code, request}
    readonly property var xmrWallet: (cardRoot.xmr && cardRoot.xmr.wallet) ? cardRoot.xmr.wallet : null
    readonly property int xmrDepth: cardRoot.xmr ? Number(cardRoot.xmr.confirmDepth || 10) : 10
    // a payment request: one share, and the creditor's own share nothing
    readonly property bool isRequest: cardRoot.isSplit && cardRoot.parts.length === 1
                                      && String(cardRoot.split.creditorShare || "") === "0"
    // a send (exo-dcc.32): a request its own payer proposed — they send it, nobody asked
    readonly property bool isSend: {
        if (!cardRoot.isRequest) return false;
        var ps = (cardRoot.card && Array.isArray(cardRoot.card.proposedBy)) ? cardRoot.card.proposedBy : [];
        return ps.length > 0 && MusterStyle.personKey(ps[0].who) === MusterStyle.personKey(cardRoot.parts[0].who);
    }
    // a request's headline: who asks whom for what — or, for a send, who sends whom what
    function requestLine() {
        if (!cardRoot.isRequest) return "";
        var p = cardRoot.parts[0];
        var who = String(p.name || "").length > 0 ? String(p.name) : String(p.who || "").slice(0, 10) + "…";
        var memo = String(cardRoot.split.memo || "").length > 0 ? " · " + String(cardRoot.split.memo) : "";
        if (cardRoot.isSend)
            return cardRoot.iAmCreditor
                   ? qsTr("%1 sends you %2 %3%4").arg(who).arg(cardRoot.eth(cardRoot.split.total)).arg(cardRoot.unit).arg(memo)
                   : cardRoot.iAmDebtor
                   ? qsTr("You send %1 %2 %3%4").arg(cardRoot.creditorName).arg(cardRoot.eth(cardRoot.split.total)).arg(cardRoot.unit).arg(memo)
                   : qsTr("%1 sends %2 %3 %4%5").arg(who).arg(cardRoot.creditorName)
                         .arg(cardRoot.eth(cardRoot.split.total)).arg(cardRoot.unit).arg(memo);
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
        if (p.settled) return cardRoot.iAmCreditor ? qsTr("paid — not seen by your wallet yet")
                                                   : qsTr("paid — waiting for %1 to see it").arg(cardRoot.creditorName);
        if (p.unresolved) return qsTr("sent — not landed yet; Muster keeps watching and won't send it twice");
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
    // the header's icon and status (exo-720.10): the same facts the card shows below, in a word
    readonly property string headerIcon: {
        var c = cardRoot.card || {};
        if (cardRoot.kind === "address-request") return "ask-address";
        if (cardRoot.kind === "address-share") return "link";
        if (cardRoot.kind === "send-receipt" || cardRoot.kind === "intent-approve") return "check";
        if (c.split || c.settleUp) return "split";
        if (String(c.statement || "").length > 0) return "check";
        if (String(c.action || "").length > 0) return "code";
        return "coin";
    }
    // What a person can do on this card now: the primary actions' own rules, in one place,
    // so the status pill and the buttons never disagree.
    readonly property bool canApprove: cardRoot.kind === "intent-propose" && cardRoot.schemaKnown
        && !(cardRoot.card && cardRoot.card.approvedByMe)
        && !cardRoot.ready
        // a decline is final (exo-720): who declined does not approve, and a
        // proposal too many declined is closed
        && !cardRoot.declinedByMe && !cardRoot.isDeclined
        // a split: only who it names agrees — each debtor, and the creditor to payTo
        // being theirs (exo-770), never to an address this client does not hold
        && (!cardRoot.isSplit || cardRoot.iAmDebtor || (cardRoot.iAmCreditor && (cardRoot.payToMine || cardRoot.payToMineUnknown)))
        && (!cardRoot.isSettleUp || !!cardRoot.settleUp.iAmParty)
        && !cardRoot.vouchedNotMine    // never vouch for an address this client does not hold
        && !cardRoot.splitExpired      // past its expiry an agreement is refused (inv 2)
    readonly property bool canPayShare: cardRoot.kind === "intent-propose" && cardRoot.isSplit && cardRoot.iAmDebtor && !cardRoot.isXmr
        && cardRoot.ready && !cardRoot.paid && !cardRoot.splitExpired
        && cardRoot.myPart !== null && !cardRoot.myPart.settled && !cardRoot.myPart.paying
        && !cardRoot.myPart.covered
    readonly property bool canPaySettle: cardRoot.kind === "intent-propose" && cardRoot.isSettleUp && cardRoot.ready
        && !cardRoot.settleUp.expired
        && cardRoot.myTransfer !== null
    readonly property bool needsMe: canApprove || canPayShare || canPaySettle

    // What I just clicked, until the room's state shows it (exo-49d): the button gives way
    // to "Sending your approval…" at once, rather than sitting there inviting a second
    // click. It clears when the action no longer applies (the log caught up) or after 30 s,
    // when the button comes back; a refusal is reported by the room's own notice.
    property string sending: ""            // "approve" | "pay" | "deny" | ""
    function markSending(what) { cardRoot.sending = what; sendingClear.restart(); }
    Timer { id: sendingClear; interval: 30000; onTriggered: cardRoot.sending = "" }
    onCanApproveChanged: if (!cardRoot.canApprove && (cardRoot.sending === "approve" || cardRoot.sending === "deny")) cardRoot.sending = ""
    onCanPayShareChanged: if (!cardRoot.canPayShare && cardRoot.sending === "pay") cardRoot.sending = ""
    onCanPaySettleChanged: if (!cardRoot.canPaySettle && cardRoot.sending === "pay") cardRoot.sending = ""

    // The status in words (exo-ce0): what happens next, and who it waits on — "Needs you",
    // "Waiting for Bob", "Ready to settle", "Sent to the chain", "Paid 1 of 2", "Paid".
    // `stage` is the intent's lifecycle state; `state` the card's coarser one.
    readonly property string stage: String((cardRoot.card && (cardRoot.card.stage || cardRoot.card.state)) || "")
    readonly property bool settlesOnChain: !!(cardRoot.card && cardRoot.card.profile
                                              && String(cardRoot.card.profile.settlement || "none") !== "none")
    // who a proposal still waits on to agree, by name where the card names them (a split's parties)
    function waitingFor() {
        var left = Math.max(0, cardRoot.threshold - cardRoot.approvals);
        if (cardRoot.isSplit) {
            var ap = (cardRoot.card && Array.isArray(cardRoot.card.approvers)) ? cardRoot.card.approvers : [];
            var names = [];
            for (var i = 0; i < cardRoot.parts.length; ++i) {
                var p = cardRoot.parts[i], agreed = false;
                for (var j = 0; j < ap.length; ++j) if (String(ap[j].who) === String(p.part)) agreed = true;
                if (!agreed) names.push(p.mine ? qsTr("you") : String(p.name || "").length > 0 ? String(p.name) : String(p.who || "").slice(0, 8) + "…");
            }
            if (!cardRoot.creditorAgreed && cardRoot.split) names.push(cardRoot.iAmCreditor ? qsTr("you") : cardRoot.creditorName);
            if (names.length === 1) return qsTr("Waiting for %1").arg(names[0]);
            if (names.length === 2) return qsTr("Waiting for %1 and %2").arg(names[0]).arg(names[1]);
            if (names.length > 2) return qsTr("Waiting for %1 people").arg(names.length);
        }
        if (cardRoot.rounds > 1 && cardRoot.roundNo > 1)
            return qsTr("Round %1 of %2").arg(cardRoot.roundNo).arg(cardRoot.rounds);
        return left === 1 ? qsTr("Waiting for 1 more") : left > 1 ? qsTr("Waiting for %1 more").arg(left) : qsTr("Waiting");
    }
    readonly property string stateWord: {
        var st = cardRoot.stage;
        if (cardRoot.isDeclined || st === "declined") return qsTr("Declined");
        if (st === "expired" || cardRoot.splitExpired) return qsTr("Expired");
        if (cardRoot.sending === "approve") return qsTr("Sending your approval…");
        if (cardRoot.sending === "deny") return qsTr("Sending…");
        if (cardRoot.sending === "pay") return qsTr("Sending your payment…");
        if (cardRoot.canApprove) return qsTr("Needs you");
        if (cardRoot.canPayShare || cardRoot.canPaySettle) return qsTr("Your turn to pay");
        var parts = cardRoot.isSplit || cardRoot.isSettleUp;
        if (st === "proposed" || st === "collecting") return cardRoot.waitingFor();
        if (st === "executable" || st === "ready") return parts ? qsTr("Agreed · paying") : cardRoot.settlesOnChain ? qsTr("Ready to settle") : qsTr("Agreed");
        if (st === "submitted") return parts ? qsTr("Paying") : qsTr("Sent to the chain");
        if (st === "settling") {
            if (!parts) return qsTr("Settling");
            var n = 0;
            for (var i = 0; i < cardRoot.parts.length; ++i) if (cardRoot.parts[i].confirmed) ++n;
            return qsTr("Paid %1 of %2").arg(n).arg(cardRoot.parts.length);
        }
        if (st === "final" || st === "paid") return parts ? qsTr("Paid") : cardRoot.settlesOnChain ? qsTr("Settled") : qsTr("Agreed");
        return st.length > 0 ? st.charAt(0).toUpperCase() + st.slice(1) : "";
    }
    readonly property string stateTone: {
        var st = cardRoot.stage;
        if (cardRoot.isDeclined || st === "declined" || st === "expired" || cardRoot.splitExpired) return "refused";
        if (cardRoot.sending.length > 0) return "info";
        if (cardRoot.needsMe) return "needs";
        if (st === "final" || st === "paid") return "settled";
        if (st === "executable" || st === "ready" || st === "submitted" || st === "settling") return "info";
        return "waiting";
    }

    // The kinds this component knows how to draw. Anything else is not ours to
    // render, so we disappear and the thread shows plain text. `voice-note` is never
    // added here: a message cannot pose as a voice note (voice-notes.md §7).
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

    // The receipt is the one moment value leaves the room, so it carries the
    // outside ground inside it — every other kind stays on the raised surface.
    radius: Theme.spacing.radiusLarge
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

        // ── the header (exo-720.10): what kind of card, what it is, where it stands ──
        RowLayout {
            objectName: "cardTitleRow"
            Layout.fillWidth: true
            Layout.bottomMargin: Theme.spacing.tiny
            spacing: Theme.spacing.small
            Rectangle {
                implicitWidth: 26; implicitHeight: 26
                radius: Theme.spacing.radiusMedium
                color: cardRoot.kind === "send-receipt" ? MusterStyle.settledSoft : MusterStyle.needsSoft
                LogosIcon {
                    anchors.centerIn: parent
                    width: 16; height: 16
                    source: MusterStyle.icon(cardRoot.headerIcon)
                    color: cardRoot.kind === "send-receipt" ? MusterStyle.settled : MusterStyle.needs
                }
            }
            LogosText {
                objectName: "cardHeading"
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: cardRoot.kind === "address-request" ? qsTr("Asked for an address")
                    : cardRoot.kind === "address-share" ? qsTr("Shared an address")
                    : cardRoot.kind === "intent-propose"
                      ? (String((cardRoot.card && cardRoot.card.heading) || "").length > 0 ? String(cardRoot.card.heading)
                         : String((cardRoot.card && cardRoot.card.statement) || "").length > 0 ? qsTr("Proposed a statement")
                         : String((cardRoot.card && cardRoot.card.action) || "").length > 0 ? qsTr("Proposed an action")
                         : qsTr("Proposed a payment"))
                    : cardRoot.kind === "intent-approve" ? qsTr("Approved")
                    : qsTr("Payment sent")
                color: Theme.palette.text
                font.pixelSize: MusterStyle.cardBody
                font.weight: Theme.typography.weightBold
            }
            StatusPill {
                objectName: "cardStatePill"
                visible: cardRoot.kind === "intent-propose" && cardRoot.stateWord.length > 0
                text: cardRoot.stateWord
                tone: cardRoot.stateTone
            }
        }

        // address-request (CardAddressRequest.qml)
        CardAddressRequest { cardRoot: cardItem }

        // address-share (CardAddressShare.qml)
        CardAddressShare { cardRoot: cardItem }

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
            font.pixelSize: MusterStyle.cardBody
        }

        // schema unknown (CardUnknownSchema.qml)
        CardUnknownSchema { cardRoot: cardItem }

        // intent-propose (CardProposal.qml)
        CardProposal { cardRoot: cardItem }

        // send-receipt (CardReceipt.qml)
        CardReceipt { cardRoot: cardItem }

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
            text: (cardRoot.isDeclined
                   ? qsTr("Declined: it can no longer reach %1 of %2. %3 declined: %4")
                         .arg(cardRoot.threshold).arg(cardRoot.signerCount).arg(cardRoot.declines)
                   : qsTr("%1 declined: %2").arg(cardRoot.declines)).arg(
                      ((cardRoot.card && Array.isArray(cardRoot.card.declinerNames) && cardRoot.card.declinerNames.length > 0)
                         ? cardRoot.card.declinerNames : cardRoot.decliners.map(function (d) { return { who: d, name: "" }; }))
                      .map(function (d) {
                          var n = String(d.name || "");
                          if (n.length > 0) return n;
                          var x = String(d.who || ""); return x.length > 12 ? x.slice(0, 6) + "…" + x.slice(-4) : x; }).join(", "))
            color: Theme.palette.warning
            font.pixelSize: MusterStyle.cardCaption
        }

        // what this needs (CardNeeds.qml)
        CardNeeds { cardRoot: cardItem }

        // a Monero multisig spend (ADR-020): where each signer's own wallet stands
        ColumnLayout {
            objectName: "cardXmrMsig"
            Layout.fillWidth: true
            visible: cardRoot.xmrMsig !== null
            spacing: 2
            readonly property var m: cardRoot.xmrMsig || ({})
            readonly property int signerCount: (m.signers || []).length
            LogosText {
                text: qsTr("Monero multisig")
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.cardCaption
                font.weight: Theme.typography.weightMedium
            }
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                // until the first M have approved, nobody is a signer yet: say who will be
                text: parent.signerCount === 0
                      ? (Number(cardRoot.card && cardRoot.card.threshold || 0) > 0
                         ? qsTr("Signers: the first %1 to approve, each from their own wallet").arg(cardRoot.card.threshold)
                         : qsTr("Signers: the first to approve, each from their own wallet"))
                      : qsTr("Signers: %1, each from their own wallet").arg(parent.signerCount)
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.cardCaption
            }
            LogosText {
                Layout.fillWidth: true
                visible: parent.signerCount > 0
                text: qsTr("Synced: %1 of %2").arg((parent.m.synced || []).length).arg(parent.signerCount)
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.cardCaption
            }
            LogosText {
                Layout.fillWidth: true
                visible: parent.signerCount > 0
                text: qsTr("Signed: %1 of %2").arg((parent.m.signed || []).length).arg(parent.signerCount)
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.cardCaption
            }
            LogosText {
                Layout.fillWidth: true
                visible: String(parent.m.txids || "").length > 0
                text: qsTr("Submitted: %1…").arg(String(parent.m.txids || "").slice(0, 12))
                color: Theme.palette.textSecondary
                font.family: MusterStyle.mono
                font.pixelSize: MusterStyle.cardCaption
            }
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                visible: String(parent.m.last || "").length > 0
                text: qsTr("Your wallet: %1").arg(String(parent.m.last || ""))
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.cardCaption
            }
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("Each signer's own wallet signs only if what it shows is this spend.")
                color: Theme.palette.textTertiary
                font.pixelSize: MusterStyle.cardCaption
            }
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("A Monero transaction has no expiry: a set a signer signed could still be completed outside the room after this proposal expires.")
                color: Theme.palette.textTertiary
                font.pixelSize: MusterStyle.cardCaption
            }
        }

        // ── actions ────────────────────────────────────────────────────────
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
            font.pixelSize: MusterStyle.cardCaption
        }

        LogosText {
            objectName: "cardSplitNote"
            visible: cardRoot.isSplit && cardRoot.splitNote.length > 0
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: cardRoot.splitNote
            color: cardRoot.splitNote.indexOf("⚠") === 0 ? Theme.palette.warning : Theme.palette.textSecondary
            font.pixelSize: MusterStyle.cardCaption
        }

        // the card's actions in one row (exo-720.10): the one that moves it forward first and
        // Primary, the rest quiet. Each keeps the rule for when it shows, as before.
        Flow {
            objectName: "cardActions"
            Layout.fillWidth: true
            // no `visible` here: a child reads as hidden while its parent is, so a row shown
            // only when a child shows would never show. Empty, it takes no height.
            Layout.topMargin: childrenRect.height > 0 ? Theme.spacing.small : 0
            spacing: Theme.spacing.small

            // address-request: the reader answers with an address.
            ActionButton {
                variant: LogosButton.Variant.Primary
                objectName: "cardShareAddress"
                // only to someone asked, and only until they have answered (exo-8e2)
                visible: cardRoot.kind === "address-request" && cardRoot.askedOfMe && !cardRoot.answeredByMe
                text: String((cardRoot.card && cardRoot.card.asset) || "ETH") === "BTC" ? qsTr("Share my Bitcoin address")
                      : String((cardRoot.card && cardRoot.card.asset) || "ETH") === "XMR" ? qsTr("Share my Monero address")
                      : String((cardRoot.card && cardRoot.card.asset) || "ETH") === "LEZ" ? qsTr("Share my LEZ address")
                      : qsTr("Share an address")
                onClicked: cardRoot.shareAddress()
            }

            // intent-propose: approve while it still needs you. Settling a ready
            // Safe intent is the room's "Settle on-chain" affordance (Room.qml's
            // ready box), driven by the verified fold — not a card button. The old
            // "Pay it"/"Drop it" buttons had no wired path (no coordinate_drop, and
            // paying flows through propose→approve→settle), so they only ever fired
            // signals nothing listened to; removed rather than leave dead controls.
            ActionButton {
                variant: LogosButton.Variant.Primary
                objectName: "cardApprove"
                visible: cardRoot.canApprove && cardRoot.sending === ""
                text: cardRoot.isSettleUp ? qsTr("Agree to settle up")
                    : !cardRoot.isSplit ? qsTr("Approve")
                    : cardRoot.iAmDebtor ? qsTr("Agree to my share")
                    // a send's recipient: accepting is their word that the address is theirs
                    : cardRoot.isSend ? qsTr("Accept — %1 is my address").arg(cardRoot.shortPayTo(String((cardRoot.split && cardRoot.split.payTo) || "")))
                    : cardRoot.isRequest ? qsTr("Agree — %1 is mine").arg(cardRoot.shortPayTo(String((cardRoot.split && cardRoot.split.payTo) || "")))
                    : qsTr("Agree — I paid, and %1 is mine").arg(cardRoot.shortPayTo(String((cardRoot.split && cardRoot.split.payTo) || "")))
                onClicked: { cardRoot.markSending("approve"); cardRoot.approve(); }
            }

            // A settle-up (exo-3c6): once every party agreed, each pays their own net payments —
            // derived from the agreed settle-up, one at a time; the recipient's client confirms.
            ActionButton {
                variant: LogosButton.Variant.Primary
                objectName: "cardPaySettle"
                visible: cardRoot.canPaySettle && cardRoot.sending === ""
                text: cardRoot.myTransfer
                      ? qsTr("Pay %1 %2 to %3").arg(cardRoot.eth(cardRoot.myTransfer.amount)).arg(cardRoot.unit)
                            .arg(String(cardRoot.myTransfer.toName || "").length > 0 ? cardRoot.myTransfer.toName
                                 : String(cardRoot.myTransfer.to).slice(0, 10) + "…")
                      : ""
                onClicked: { cardRoot.markSending("pay"); cardRoot.settlePart(); }
            }

            // A split (exo-a90): once everyone named has agreed, each pays their OWN share from
            // their own wallet. The module derives the payment from the agreed split — this
            // button carries no amount and no address.
            ActionButton {
                variant: LogosButton.Variant.Primary
                objectName: "cardPayShare"
                visible: cardRoot.canPayShare && cardRoot.sending === ""
                text: cardRoot.myPart ? qsTr("Pay my share — %1 %2").arg(cardRoot.eth(cardRoot.myPart.amount)).arg(cardRoot.unit)
                                      : qsTr("Pay my share")
                onClicked: { cardRoot.markSending("pay"); cardRoot.settlePart(); }
            }

            ActionButton {
                variant: LogosButton.Variant.Primary
                objectName: "cardRenewSplit"
                visible: cardRoot.kind === "intent-propose" && cardRoot.isSplit && cardRoot.splitExpired
                         && cardRoot.ready && !!cardRoot.split.renewable && (cardRoot.iAmDebtor || cardRoot.iAmCreditor)
                text: qsTr("Renew the unpaid shares")
                onClicked: cardRoot.renewSplit()
            }

            // Deny: decline to take part while it still needs signers. Informational —
            // the threshold is unchanged; the room sees who is out. One per member; folds once.
            ActionButton {
                quiet: true
                objectName: "cardDeny"
                visible: cardRoot.kind === "intent-propose" && cardRoot.schemaKnown
                    && !(cardRoot.card && cardRoot.card.approvedByMe)
                    && !cardRoot.declinedByMe
                    && !cardRoot.ready
                    && !cardRoot.isDeclined
                    && (!cardRoot.isSplit || cardRoot.iAmDebtor || cardRoot.iAmCreditor)
                    && cardRoot.sending === ""
                text: qsTr("Deny")
                onClicked: { cardRoot.markSending("deny"); cardRoot.deny(); }
            }

            // "Who sees this?" (exo-720.10): this proposal's flow, in the room's Privacy tab
            ActionButton {
                objectName: "cardWhoSees"
                quiet: true
                visible: cardRoot.kind === "intent-propose" && cardRoot.schemaKnown
                text: qsTr("Who sees this?")
                onClicked: cardRoot.whoSees()
            }
            // Download audit trail (exo-403): one self-verifying file of everything this
            // intent's approvals cover, plus a readable report generated from it. A Details action.
            ActionButton {
                quiet: true
                objectName: "cardDownloadAudit"
                visible: cardRoot.kind === "intent-propose" && cardRoot.schemaKnown && cardRoot.detailsOpen
                text: qsTr("Download audit trail")
                onClicked: cardRoot.downloadAudit()
            }
            ActionButton {
                quiet: true
                objectName: "cardDetailsToggle"
                visible: cardRoot.kind === "intent-propose" && cardRoot.schemaKnown
                text: cardRoot.detailsOpen ? qsTr("Hide details") : qsTr("Details")
                Accessible.description: qsTr("How this works, what it needs, what you would sign, and where every input came from")
                onClicked: cardRoot.detailsOpen = !cardRoot.detailsOpen
            }
        }

        LogosText {
            objectName: "cardAuditStatus"
            visible: cardRoot.auditStatus.length > 0
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: cardRoot.auditStatus
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.cardCaption
        }
    }
}
