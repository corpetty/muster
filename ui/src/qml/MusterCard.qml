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
    function verifyDomain() {
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
    // Share one of MY holdings to fill a slot this proposal asks of me (the "From you"
    // picker, exo-45e K6): (requirement name, the chosen candidate's PUBLIC face).
    signal shareMaterial(string requirement, string pub)
    // A remedy that lives in Settings (an RPC to configure / repoint).
    signal openSettings()
    property bool needsOpen: false
    readonly property var readiness: (cardRoot.card && cardRoot.card.readiness) ? cardRoot.card.readiness : null
    // "From you" (exo-45e K6): which of my own holdings fill the slots this asks of me.
    readonly property var offers: (cardRoot.card && cardRoot.card.offers) ? cardRoot.card.offers : null
    // The policy this intent runs under (from readiness), used to gate the picker below.
    readonly property string policy: (cardRoot.readiness && cardRoot.readiness.policy)
                                     ? String(cardRoot.readiness.policy) : ""
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
    signal shareAddress()
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
                : cardRoot.kind === "intent-propose" ? qsTr("Proposed a payment")
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
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("This room needs somewhere to send funds. Share an address to continue.")
                color: Theme.palette.textSecondary
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.secondaryText
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
                Layout.fillWidth: true
                wrapMode: Text.WrapAnywhere
                elide: Text.ElideRight
                text: {
                    var form = cardRoot.card && cardRoot.card.form !== undefined
                        ? Number(cardRoot.card.form) : 0;
                    var addr = cardRoot.card && cardRoot.card.address
                        ? String(cardRoot.card.address).replace(/\s+/g, "") : "";
                    var shown = addr.slice(0, 48) + (addr.length > 48 ? "…" : "");
                    return (form === 1 ? qsTr("public account") : qsTr("shielded"))
                        + (shown.length > 0 ? "  ·  " + shown : "");
                }
                color: Theme.palette.textTertiary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.secondaryText
            }

            // A public account is worth a word: the payer should know the
            // destination is readable before choosing how to pay.
            LogosText {
                Layout.fillWidth: true
                visible: cardRoot.card && cardRoot.card.form !== undefined
                    && Number(cardRoot.card.form) === 1
                wrapMode: Text.WordWrap
                text: qsTr("Anyone reading the zone can see what lands here.")
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.badgeText
            }

            // Close the loop: use the address the counterparty just disclosed as the
            // recipient of the payment being composed, instead of retyping it. Only for
            // a public account (form 1) that carries an address.
            LogosButton {
                objectName: "cardUseAddress"
                visible: cardRoot.card && Number(cardRoot.card.form || 0) === 1
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
                            { k: "paid", t: qsTr("paid") }]

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
                        readonly property var who: cardRoot.card && cardRoot.card.approvers
                            && slot.index < cardRoot.card.approvers.length
                            ? cardRoot.card.approvers[slot.index] : null

                        implicitWidth: 22
                        implicitHeight: 22
                        radius: 11
                        color: slot.filled ? Theme.palette.success : "transparent"
                        border.width: slot.filled ? 0 : 1
                        border.color: Theme.palette.borderDefault

                        LogosText {
                            anchors.centerIn: parent
                            visible: slot.filled
                            text: slot.who && slot.who.initials
                                ? String(slot.who.initials) : ""
                            color: Theme.palette.background
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

            // The honesty caveat this card must not overstate. The count above
            // is real in the room; the chain is not asked to check it.
            LogosText {
                Layout.fillWidth: true
                Layout.topMargin: 2
                wrapMode: Text.WordWrap
                text: qsTr("The threshold is authenticated in the room; "
                           + "the chain does not enforce it.")
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.badgeText
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
            text: qsTr("%1 declined: %2").arg(cardRoot.declines).arg(cardRoot.decliners.map(function (d) {
                      var x = String(d); return x.length > 12 ? x.slice(0, 6) + "…" + x.slice(-4) : x; }).join(", "))
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
                    if (cardRoot.needsOpen && !cardRoot.readiness) cardRoot.needs();
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
                        required property var modelData
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
                                    + (modelData.party === "contributor" ? qsTr(" (each signer)") : "")
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
                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: (modelData.kind === "module" ? qsTr("Install: ") : qsTr("To fix: ")) + String(modelData.remedy || "")
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
                                visible: (modelData.kind === "infra" && modelData.name !== "lez-account")
                                         || modelData.kind === "environment"
                                text: qsTr("Open settings")
                                variant: LogosButton.Variant.Secondary
                                onClicked: cardRoot.openSettings()
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
            visible: cardRoot.kind === "address-request"
            Layout.fillWidth: true
            text: qsTr("Share an address")
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
            Layout.fillWidth: true
            text: qsTr("Approve")
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
            Layout.fillWidth: true
            text: qsTr("Deny")
            variant: LogosButton.Variant.Secondary
            onClicked: cardRoot.deny()
        }
    }
}
