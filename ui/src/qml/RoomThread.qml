import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The room's timeline (exo-720.3, moved verbatim out of Room.qml): chat and cards in
// the order they were sent. Each `room.x` is the Room's own state, as before the move.
// ── the conversation ──────────────────────────────────────────────
// One timeline. Chat and cards interleave in the order they were sent —
// proposals are cards IN the conversation, not a side list. A message whose
// body is an `intent-ref` card resolves to the live proposal from the
// verified fold (state + verify + provenance), rendered inline with its own
// approve affordance; address-share / receipt cards render in place; a voice note
// draws from its row's `voice` field alone (CardVoiceNote, docs/design/voice-notes.md
// §7); anything else is plain text, a card kind this thread does not draw included.
Rectangle {
    required property var room   // the Room this piece belongs to (Room.qml's roomItem)

    id: threadRoot
    visible: room.joined
    Layout.fillWidth: true
    Layout.fillHeight: true
    // the page itself, not a box on it: the conversation owns the screen (exo-720.7)
    color: "transparent"

    // the pinned line's Review (RoomPinned): scroll to that proposal's card
    Connections {
        target: threadRoot.room
        function onJumpRequested(intentId) {
            var msgs = threadRoot.room.threadItems;
            for (var i = 0; i < msgs.length; ++i) {
                try {
                    var o = JSON.parse(msgs[i].body);
                    if (o && String(o.kind || "") === "intent-ref" && String(o.intentId || "") === intentId) {
                        thread.positionViewAtIndex(i, ListView.Center);
                        return;
                    }
                } catch (e) {}
            }
        }
    }

    ListView {
        id: thread
        objectName: "messageThread"
        anchors.fill: parent
        anchors.leftMargin: Theme.spacing.xlarge
        anchors.rightMargin: Theme.spacing.xlarge
        anchors.topMargin: Theme.spacing.medium
        anchors.bottomMargin: Theme.spacing.medium
        clip: true
        spacing: Theme.spacing.small
        model: room.threadItems
        onCountChanged: positionViewAtEnd()

        delegate: Item {
            id: msg
            // Both are REQUIRED: once a delegate declares any required property,
            // Qt 6 stops injecting context properties, so `modelData` must be
            // declared too or it reads as undefined (which silently blanks every
            // card — parsedCard parse fails → all rows fall through to empty
            // chat text). `index` drives the duplicate-ref collapse below.
            required property int index
            required property var modelData
            width: thread.width
            // A duplicate ref collapses to nothing — re-proposing the same
            // effect (same content-addressed id) posts a second ref to the
            // one intent; the intent is one thing, so show it once.
            implicitHeight: msg.isDupRef ? 0 : rowCol.implicitHeight

            // A body that parses to an object with a `kind` is a typed card.
            // `intent-ref` points at a proposal in the verified fold; other
            // kinds (address-share / receipt) are peer data rendered in place;
            // anything else is plain chat text. `voice-note` is reserved: a voice
            // note comes only from the row's `voice` field, which only the module's
            // fold of the note's signed parts sets, so a message whose body claims
            // that kind is the poster's own words, drawn as text under their name
            // (docs/design/voice-notes.md §7).
            readonly property var parsedCard: {
                try {
                    var o = JSON.parse(modelData.body);
                    if (o && String(o.kind || "") === "voice-note") return null;
                    return (o && (o.kind || o.type)) ? o : null;
                } catch (e) { return null; }
            }
            // A voice note's row: its `voice` field ({v, note, durationMs, state}), set by
            // the module's fold alone, and the note's author the one that fold verified.
            readonly property var voice: (modelData && modelData.voice && typeof modelData.voice === "object")
                                         ? modelData.voice : null
            readonly property bool isVoice: msg.voice !== null
            // Plain text: a voice row never is; a card the thread draws never is; and a card
            // kind it does not draw falls back to its text, so a newer client's card shows as
            // what was posted, never as nothing.
            readonly property bool isText: !msg.isVoice
                                           && (msg.parsedCard === null || (!msg.isIntentRef && !otherCard.known))
            readonly property bool isIntentRef:
                msg.parsedCard && String(msg.parsedCard.kind || "") === "intent-ref"
            readonly property var liveIntent:
                msg.isIntentRef ? room.intentById(msg.parsedCard.intentId) : null

            // Who authored this line, by name: "you" for our own, the contact
            // alias when we've named them, else a short id — never raw 64-byte
            // hex in the timeline (the module resolves alias/self on each message).
            readonly property string authorName: {
                if (modelData.self) return qsTr("you");
                var a = String(modelData.alias || "");
                if (a.length > 0) return a;
                return String(modelData.author || "?").substring(0, 10);
            }

            // True when an EARLIER message already referenced this intent —
            // so only the first ref to an intent renders its card.
            readonly property bool isDupRef: {
                if (!msg.isIntentRef) return false;
                var id = String(msg.parsedCard.intentId || "");
                var msgs = room.threadItems;
                for (var i = 0; i < msg.index && i < msgs.length; ++i) {
                    try {
                        var o = JSON.parse(msgs[i].body);
                        if (o && String(o.kind || "") === "intent-ref"
                             && String(o.intentId || "") === id)
                            return true;
                    } catch (e) {}
                }
                return false;
            }

            // Time in the thread (exo-52d): a divider at each new day, and a run of lines from
            // one person within five minutes under one header, as chat clients do.
            readonly property var prev: msg.index > 0 && msg.index - 1 < room.threadItems.length
                                        ? room.threadItems[msg.index - 1] : null
            readonly property bool newDay: !!modelData.ts
                                           && (!msg.prev || !msg.prev.ts
                                               || MusterStyle.dayKey(msg.prev.ts) !== MusterStyle.dayKey(modelData.ts))
            function who(a) { return String(a || "").replace(/^0x/, "").toLowerCase(); }
            function isChat(m) {
                if (m && m.voice) return false;     // a voice note names its author itself
                try { var o = JSON.parse(m.body); return !(o && (o.kind || o.type)); }
                catch (e) { return true; }
            }
            readonly property bool continues: !msg.newDay && !!msg.prev && msg.parsedCard === null && msg.isText
                                              && msg.isChat(msg.prev)
                                              && msg.who(msg.prev.author) === msg.who(modelData.author)
                                              && MusterStyle.msOf(modelData.ts) - MusterStyle.msOf(msg.prev.ts) < 5 * 60 * 1000

            // reveal the signature field for THIS inline proposal.
            property bool approving: false
            // reveal the outside-signer panel (PSBT) for THIS inline proposal.
            property bool outsideOpen: false

            ColumnLayout {
                id: rowCol
                width: parent.width
                visible: !msg.isDupRef
                spacing: Theme.spacing.tiny

                // ── the day, once at its first message ─────────────────────
                RowLayout {
                    objectName: "dayDivider"
                    visible: msg.newDay
                    Layout.fillWidth: true
                    Layout.topMargin: msg.index > 0 ? Theme.spacing.medium : 0
                    Layout.bottomMargin: Theme.spacing.tiny
                    spacing: Theme.spacing.medium
                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.palette.borderSubtle }
                    LogosText {
                        text: msg.newDay ? MusterStyle.dayLabel(modelData.ts) : ""
                        color: Theme.palette.textTertiary
                        font.pixelSize: MusterStyle.caption
                        font.weight: Theme.typography.weightMedium
                    }
                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.palette.borderSubtle }
                }

                // ── a proposal, inline (live state from the verified fold) ──
                MusterCard {
                    id: liveCard
                    visible: msg.isIntentRef && msg.liveIntent !== null
                    Layout.fillWidth: true
                    card: msg.liveIntent ? room.intentToCard(msg.liveIntent) : ({})
                    // Primary: sign in-app with YOUR own identity — no paste. An
                    // empty signature tells the module to endorse the re-derived
                    // materialization with the keystore (Ed25519 for a room-native
                    // driver where you are a member; secp for a Safe you own).
                    onApprove: {
                        if (room.backend && msg.liveIntent)
                            room.backend.contributeInRoom(String(msg.liveIntent.id || ""), "", "");
                    }
                    onNeeds: if (room.backend && msg.liveIntent) {
                        room.backend.loadReadiness(String(msg.liveIntent.id || ""));
                        room.backend.loadOffers(String(msg.liveIntent.id || ""));
                    }
                    onDeny: if (room.backend && msg.liveIntent) room.backend.declineInRoom(String(msg.liveIntent.id || ""))
                    onDownloadAudit: if (room.backend && msg.liveIntent) room.backend.downloadAudit(String(msg.liveIntent.id || ""))
                    onWhoSees: room.showWhoSees(msg.liveIntent ? String(msg.liveIntent.id || "") : "")
                    auditStatus: msg.liveIntent ? room.auditStatusFor(String(msg.liveIntent.id || "")) : ""
                    // Share one of my holdings to fill a slot (the "From you" picker, K6):
                    // the module publishes only the chosen PUBLIC face (s1).
                    onShareMaterial: function(requirement, pub) {
                        if (room.backend && msg.liveIntent)
                            room.backend.shareMaterial(String(msg.liveIntent.id || ""), requirement, pub);
                    }
                    // a split (exo-a90): pay MY share (derived by the module from the
                    // agreed split), or — as the creditor — mark a share received
                    // outside muster. Payments the creditor's own RPC shows are
                    // confirmed on the intents tick without a click.
                    onSettlePart: if (room.backend && msg.liveIntent)
                                      room.backend.settlePart(String(msg.liveIntent.id || ""))
                    onConfirmPart: function(part) {
                        if (room.backend && msg.liveIntent)
                            room.backend.confirmPart(String(msg.liveIntent.id || ""), part, "");
                    }
                    onRenewSplit: if (room.backend && msg.liveIntent)
                                      room.backend.renewSplit(String(msg.liveIntent.id || ""))
                    // a Monero request (exo-dcc.5): "I paid", my claim (a txid if given) —
                    // never a confirmation; and the creditor's wallet, opened in Monero Wallet
                    onReportPaid: function (tx) {
                        if (room.backend && msg.liveIntent)
                            room.backend.reportPaid(String(msg.liveIntent.id || ""), tx);
                    }
                    onOpenMoneroWallet: function (wallet) { room.moneroWalletRequested(wallet); }
                    onPresentMoneroWallet: function (address, amount) { room.moneroWalletPresentRequested(address, amount); }
                    moneroWalletFilled: room.moneroWalletFilled()
                    moneroWalletNote: room.moneroWalletNote()
                    splitNote: (room.splitResult && room.splitResult.id && msg.liveIntent
                                && String(room.splitResult.id) === String(msg.liveIntent.id || "")
                                && room.splitResult.op !== "propose")
                               ? (room.splitResult.error
                                  ? (String(room.splitResult.error) === "paying"
                                     ? qsTr("Your earlier payment of this share has not landed yet. Muster will not send another while it might; it shows as paid once it lands.")
                                     : String(room.splitResult.error).indexOf("unconfirmed: ") === 0
                                     // a Monero share read from the creditor's wallet now: not there yet
                                     ? qsTr("⚠ Not confirmed yet: %1").arg(room.moneroWhy(String(room.splitResult.error).slice(13).split(":")[0],
                                                                                           String(room.splitResult.error).slice(13)))
                                     : room.chainErrorWords(String(room.splitResult.error), room.splitResult.detail).length > 0
                                     ? qsTr("⚠ %1").arg(room.chainErrorWords(String(room.splitResult.error), room.splitResult.detail))
                                     : qsTr("⚠ %1").arg(String(room.splitResult.error) + (room.splitResult.detail ? ": " + String(room.splitResult.detail) : "")))
                                  : room.splitResult.op === "pay"
                                  ? (room.myPartSettled(msg.liveIntent) ? ""
                                     : String(room.splitResult.pending || "") === "pending"
                                     // a private payment proves in the background: no
                                     // reference exists until the zone answers
                                     ? qsTr("Sending %1 %2 privately — your wallet is proving the transfer, which takes a few minutes; it shows as paid once it lands.")
                                        .arg(room.weiToEth(String(room.splitResult.amount || "0"),
                                                           Number(((msg.liveIntent && msg.liveIntent.split) || {}).decimals || 18)))
                                        .arg(String(((msg.liveIntent && msg.liveIntent.split) || {}).asset || "ETH"))
                                     // through the platform (Basecamp): nothing is sent until the person
                                     // approves it in the Logos Signer, and the reference is a request,
                                     // not a transaction ("txs:…", exo-d4d.5)
                                     : String(room.splitResult.pending || "").indexOf("txs:") === 0
                                     ? qsTr("Paying %1 %2 through the Logos Signer: approve it there. It shows as paid once it lands.")
                                        .arg(room.weiToEth(String(room.splitResult.amount || "0"),
                                                           Number(((msg.liveIntent && msg.liveIntent.split) || {}).decimals || 18)))
                                        .arg(String(((msg.liveIntent && msg.liveIntent.split) || {}).asset || "ETH"))
                                     : qsTr("Sent %1 %2 from your wallet (%3) — it shows as paid once it settles.")
                                        .arg(room.weiToEth(String(room.splitResult.amount || "0"),
                                                           Number(((msg.liveIntent && msg.liveIntent.split) || {}).decimals || 18)))
                                        .arg(String(((msg.liveIntent && msg.liveIntent.split) || {}).asset || "ETH"))
                                        .arg(String(room.splitResult.pending || "").slice(0, 12) + "…"))
                                  : room.splitResult.op === "renew"
                                  ? qsTr("Renewal proposed — it appears below; everyone who still owes a share agrees to it again.")
                                  : room.splitResult.op === "report"
                                  ? qsTr("Noted: you said you paid. Only %1's own wallet confirms it.")
                                        .arg(String((((msg.liveIntent && msg.liveIntent.split) || {}).creditorName) || qsTr("the requester")))
                                  : qsTr("Marked received."))
                               : ""
                    onOpenSettings: room.settingsRequested()
                    // install what's missing (exo-dcc.10): the shell asks Package
                    // Manager; the answers come back down; readiness is re-read
                    // (not the offers) until the module runs
                    packageRequests: room.packageRequests
                    onInstallPackage: function (pkg) { room.packageInstallRequested(pkg); }
                    onShowPackage: function (pkg) { room.packageShowRequested(pkg); }
                    onRecheckReadiness: if (room.backend && msg.liveIntent)
                                            room.backend.loadReadiness(String(msg.liveIntent.id || ""))
                }

                // Advanced: paste a signature produced elsewhere (a Safe owner on
                // another device, or a member signing off-app). Hidden behind a
                // toggle — one-click in-app Approve above is the primary path — and
                // behind the card's Details (exo-720.10).
                ActionButton {
                    objectName: "roomApprovePasteToggle"
                    // a split is agreed with the debtor's room key — there is no
                    // outside signature to paste (exo-a90)
                    visible: msg.isIntentRef && msg.liveIntent !== null && !msg.approving
                             && !msg.liveIntent.split && !msg.liveIntent.settleUp
                             && liveCard.detailsOpen
                    Layout.leftMargin: Theme.spacing.medium
                    text: qsTr("Paste a signature instead")
                    variant: LogosButton.Variant.Secondary
                    onClicked: msg.approving = true
                }

                ColumnLayout {
                    visible: msg.isIntentRef && msg.liveIntent !== null && msg.approving
                    Layout.fillWidth: true
                    Layout.leftMargin: Theme.spacing.medium
                    spacing: Theme.spacing.tiny

                    LogosText {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("Paste a signature made elsewhere over exactly what this proposal "
                                 + "signs. It counts only if it comes from a signer this proposal "
                                 + "recognizes (a Safe owner, or a room member).")
                        color: Theme.palette.textTertiary
                        font.pixelSize: MusterStyle.caption
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small

                        LogosTextField {
                            id: sigField
                            objectName: "roomApproveSig"
                            Layout.fillWidth: true
                            placeholderText: qsTr("signature (hex)")
                            font.family: MusterStyle.mono
                        }

                        // Enter adds the signature (paste, then Enter).
                        Connections {
                            target: sigField.textInput
                            function onAccepted() {
                                if (sigField.text.length > 0 && room.backend && msg.liveIntent)
                                    room.backend.contributeInRoom(String(msg.liveIntent.id || ""), sigField.text, "");
                                sigField.text = "";
                                msg.approving = false;
                            }
                        }

                        ActionButton {
                            objectName: "roomApproveSubmit"
                            text: qsTr("Add")
                            enabled: sigField.text.length > 0
                            onClicked: {
                                if (room.backend && msg.liveIntent)
                                    room.backend.contributeInRoom(String(msg.liveIntent.id || ""), sigField.text, "");
                                sigField.text = "";
                                msg.approving = false;
                            }
                        }
                    }
                }

                // Signers outside muster (exo-a50.2.6, seam S8) — always surfaced:
                // a Bitcoin intent exports as a PSBT a hardware signer, Sparrow or
                // Bitcoin Core signs; what comes back is verified by the driver like
                // an in-app approval, counts, and is shown as signed outside muster.
                ActionButton {
                    objectName: "roomOutsideToggle"
                    visible: msg.isIntentRef && msg.liveIntent !== null && room.isBtcIntent(msg.liveIntent)
                             && !msg.outsideOpen
                    Layout.leftMargin: Theme.spacing.medium
                    text: qsTr("Sign outside muster (PSBT)")
                    variant: LogosButton.Variant.Secondary
                    onClicked: {
                        msg.outsideOpen = true;
                        if (room.backend) room.backend.exportOutside(String(msg.liveIntent.id || ""));
                    }
                }

                ColumnLayout {
                    id: outsideBox
                    visible: msg.isIntentRef && msg.liveIntent !== null && room.isBtcIntent(msg.liveIntent)
                             && msg.outsideOpen
                    Layout.fillWidth: true
                    Layout.leftMargin: Theme.spacing.medium
                    spacing: Theme.spacing.tiny

                    readonly property string iid: String((msg.liveIntent && msg.liveIntent.id) || "")
                    // the export and import results, only when they name THIS intent
                    readonly property var exp: (room.outsideExport && String(room.outsideExport.intentId || "") === outsideBox.iid)
                                               ? room.outsideExport : null
                    readonly property var imp: (room.outsideImport && String(room.outsideImport.intentId || "") === outsideBox.iid)
                                               ? room.outsideImport : null

                    LogosText {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("Give this PSBT to a signer outside muster (a hardware signer, Sparrow, "
                                 + "Bitcoin Core). Paste back what it returns: each signature is checked like "
                                 + "an in-app one, counts toward the threshold, and is shown as signed outside "
                                 + "muster — it commits to the transaction, nothing more.")
                        color: Theme.palette.textTertiary
                        font.pixelSize: MusterStyle.caption
                    }

                    LogosText {
                        visible: !!(outsideBox.exp && outsideBox.exp.error)
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("⚠ No PSBT — %1").arg(String((outsideBox.exp && outsideBox.exp.error) || ""))
                        color: Theme.palette.warning
                        font.pixelSize: MusterStyle.caption
                    }

                    Rectangle {
                        visible: !!(outsideBox.exp && outsideBox.exp.encoded)
                        Layout.fillWidth: true
                        implicitHeight: Math.min(96, psbtOut.contentHeight + 2 * Theme.spacing.small)
                        radius: Theme.spacing.radiusSmall
                        color: Theme.palette.surfaceRaised
                        border.width: 1
                        border.color: Theme.palette.borderSubtle
                        clip: true
                        TextEdit {
                            id: psbtOut
                            objectName: "roomOutsidePsbt"
                            anchors.fill: parent
                            anchors.margins: Theme.spacing.small
                            readOnly: true
                            selectByMouse: true
                            wrapMode: TextEdit.WrapAnywhere
                            text: String((outsideBox.exp && outsideBox.exp.encoded) || "")
                            color: Theme.palette.textSecondary
                            font.family: MusterStyle.mono
                            font.pixelSize: MusterStyle.caption
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        ActionButton {
                            objectName: "roomOutsideCopy"
                            visible: !!(outsideBox.exp && outsideBox.exp.encoded)
                            text: qsTr("Copy PSBT")
                            variant: LogosButton.Variant.Secondary
                            onClicked: { psbtOut.selectAll(); psbtOut.copy(); psbtOut.deselect(); }
                        }
                        LogosTextField {
                            id: psbtIn
                            objectName: "roomOutsideImport"
                            Layout.fillWidth: true
                            placeholderText: qsTr("the signed PSBT (base64)")
                            font.family: MusterStyle.mono
                        }
                        ActionButton {
                            objectName: "roomOutsideImportSubmit"
                            text: qsTr("Import")
                            enabled: psbtIn.text.length > 0
                            onClicked: {
                                if (room.backend) room.backend.importOutside(outsideBox.iid, psbtIn.text);
                                psbtIn.text = "";
                            }
                        }
                        ActionButton {
                            text: qsTr("Close")
                            variant: LogosButton.Variant.Secondary
                            onClicked: msg.outsideOpen = false
                        }
                    }

                    LogosText {
                        objectName: "roomOutsideImportResult"
                        visible: outsideBox.imp !== null
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: {
                            var r = outsideBox.imp || ({});
                            if (r.error) {
                                var why = String(r.error);
                                if (why === "not-this-spend") why = qsTr("that PSBT is for a different spend — nothing was added");
                                else if (why === "no-signatures") why = qsTr("it carries no signature by one of the account's keys");
                                else if (why === "not-readable") why = qsTr("that is not a PSBT");
                                return qsTr("⚠ %1").arg(why);
                            }
                            var n = (r.imported || []).length;
                            var had = (r.already || []).length;
                            return qsTr("✓ %n signature(s) added — signed outside muster, counted.", "", n)
                                   + (had > 0 ? " " + qsTr("%n already in the room.", "", had) : "")
                                   + "  " + qsTr("State: %1").arg(String(r.state || ""));
                        }
                        color: (outsideBox.imp && outsideBox.imp.error) ? Theme.palette.warning : Theme.palette.textSecondary
                        font.pixelSize: MusterStyle.caption
                    }
                }

                // ready (executable) — settle it on-chain FROM the room. For an
                // intent whose family settles on a chain (a Safe, Bitcoin, the LEZ
                // multisig, FROST — its profile's `settlement`), Settle runs
                // coordinate_submit, which assembles the settlement from the log;
                // for a room family (threshold, attest) nothing settles on-chain,
                // so it says so. The outcome is reported honestly from the module —
                // never a false "landed".
                ColumnLayout {
                    id: readyBox
                    // Show once the intent is ready AND keep showing through
                    // submitted/settling/final — and whenever a submit outcome
                    // names this intent — so the Settle result (✓ settled, or an
                    // ⚠ error/revert) stays on screen instead of vanishing the
                    // instant Settle moves the state off "executable".
                    visible: msg.isIntentRef && msg.liveIntent !== null
                             && (["executable", "submitted", "settling", "final"]
                                    .indexOf(String((msg.liveIntent && msg.liveIntent.state) || "")) >= 0
                                 || (room.roomSubmit
                                     && String(room.roomSubmit.id || "")
                                        === String((msg.liveIntent && msg.liveIntent.id) || ""))
                                 || (room.executeResult
                                     && String(room.executeResult.id || "")
                                        === String((msg.liveIntent && msg.liveIntent.id) || "")))
                    Layout.fillWidth: true
                    Layout.leftMargin: Theme.spacing.medium
                    spacing: Theme.spacing.tiny

                    readonly property string rail: String((msg.liveIntent && msg.liveIntent.rail) || "safe")
                    readonly property string st: String((msg.liveIntent && msg.liveIntent.state) || "")
                    // Whether this intent settles on a chain at all: its family's
                    // settlement, from the driver profile (evm / bitcoin / lez …, or
                    // "none" for a room family) — never a guess from the rail. Every
                    // family that settles goes through coordinate_submit.
                    readonly property bool settles: String(((msg.liveIntent && msg.liveIntent.profile) || {}).settlement || "none") !== "none"
                    // an invoke intent settles by RUNNING the action (coordinate_execute),
                    // not by an on-chain Safe settle — the policy tells them apart.
                    readonly property bool isInvoke:
                        String((msg.liveIntent && msg.liveIntent.policy) || "") === "invoke"
                    // a split settles in PARTS — each person pays their own share — so
                    // there is nothing for one member to submit (exo-a90)
                    // settled in parts: a split, or a settle-up (exo-3c6) — never "Settle on-chain"
                    readonly property bool isSplit: !!(msg.liveIntent && (msg.liveIntent.split || msg.liveIntent.settleUp))
                    readonly property int partsDone: {
                        var ps = (msg.liveIntent && msg.liveIntent.parts) || [];
                        var n = 0;
                        for (var i = 0; i < ps.length; ++i) if (ps[i].confirmed) ++n;
                        return n;
                    }
                    // the submit outcome, only when it names THIS intent
                    readonly property var outcome: (room.roomSubmit
                        && String(room.roomSubmit.id || "") === String((msg.liveIntent && msg.liveIntent.id) || ""))
                        ? room.roomSubmit : null
                    // the invoke-execute outcome, only when it names THIS intent
                    readonly property var execOutcome: (room.executeResult
                        && String(room.executeResult.id || "") === String((msg.liveIntent && msg.liveIntent.id) || ""))
                        ? room.executeResult : null

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            // Track the folded state so the line doesn't keep
                            // saying "Ready" after the intent has been settled.
                            text: readyBox.isSplit
                                  ? (readyBox.st === "final"
                                     ? qsTr("✓ Settled — every share confirmed by who it was owed to.")
                                     // past its expiry nothing more is paid under it (exo-a90.15/16)
                                     : (msg.liveIntent && ((msg.liveIntent.split && msg.liveIntent.split.expired)
                                                           || (msg.liveIntent.settleUp && msg.liveIntent.settleUp.expired)))
                                     ? qsTr("Expired — nothing more is paid under it.")
                                     : readyBox.st === "executable"
                                     ? qsTr("✓ Agreed — each person now pays their own share.")
                                     : qsTr("Settling — %1 of %2 shares confirmed.")
                                           .arg(readyBox.partsDone)
                                           .arg(((msg.liveIntent && msg.liveIntent.parts) || []).length))
                                  : readyBox.isInvoke
                                  ? (readyBox.st === "final"
                                     ? qsTr("✓ Ran — the action executed.")
                                     : readyBox.st === "submitted"
                                     ? qsTr("Running the action…")
                                     : qsTr("✓ Ready — endorsed. Run the action."))
                                  : !readyBox.settles
                                  ? qsTr("✓ Endorsed — a signed group decision. Nothing settles on-chain.")
                                  : readyBox.st === "final"
                                  ? qsTr("✓ Settled on-chain.")
                                  : (readyBox.st === "submitted" || readyBox.st === "settling")
                                  ? qsTr("Submitted — awaiting finality…")
                                  : qsTr("✓ Ready — the approvals are collected.")
                            color: (readyBox.st === "submitted" || readyBox.st === "settling")
                                   ? Theme.palette.textSecondary : Theme.palette.success
                            font.pixelSize: Theme.typography.secondaryText
                            font.weight: Theme.typography.weightMedium
                        }
                        // invoke: run the action FROM the room (coordinate_execute).
                        ActionButton {
                            objectName: "roomExecuteButton"
                            visible: readyBox.isInvoke && readyBox.st === "executable"
                            text: qsTr("Run the action")
                            onClicked: if (room.backend)
                                           room.backend.executeInRoom(String((msg.liveIntent && msg.liveIntent.id) || ""));
                        }
                        ActionButton {
                            objectName: "roomSubmitButton"
                            // only while it is actually executable — once it is
                            // submitted/final there is nothing left to settle.
                            visible: !readyBox.isInvoke && !readyBox.isSplit && readyBox.settles && readyBox.st === "executable"
                            text: qsTr("Settle on-chain")
                            onClicked: if (room.backend)
                                           room.backend.submitInRoom(String((msg.liveIntent && msg.liveIntent.id) || ""));
                        }
                    }

                    // honest outcome line (submitted/final/failed, or an error); selectable, and
                    // its transaction hash has a Copy button
                    RowLayout {
                        visible: readyBox.outcome !== null
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        SelectableText {
                            objectName: "roomOutcomeText"
                            Layout.fillWidth: true
                            text: {
                                var o = readyBox.outcome || ({});
                                if (o.error !== undefined) {
                                    var err = String(o.error);
                                    // spell out the cases the module reports so the
                                    // reader sees *why*, not just a slug.
                                    if (err === "insufficient-signatures")
                                        return (readyBox.rail === "safe"
                                                ? qsTr("⚠ Not enough owner signatures — have %1 of %2. "
                                                       + "The approvers must be real Safe owners.")
                                                : qsTr("⚠ Not enough signatures — have %1 of %2."))
                                               .arg(String(o.have)).arg(String(o.need));
                                    if (err === "rpc-unreachable")
                                        return qsTr("⚠ Couldn't reach the chain (RPC). Is your node running? — %1")
                                               .arg(String(o.detail || ""));
                                    if (err === "not-executable")
                                        return qsTr("⚠ Not ready to settle — state is \"%1\".")
                                               .arg(String(o.state || ""));
                                    if (err === "not-onchain")
                                        return qsTr("This endorsement settles nothing on-chain — %1")
                                               .arg(String(o.detail || ""));
                                    return qsTr("⚠ ") + err + (o.detail ? " — " + String(o.detail) : "");
                                }
                                var oc = String(o.onchain || "");
                                var tx = o.txHash ? "  ·  " + String(o.txHash) : "";
                                return (oc === "final" ? qsTr("✓ Settled on-chain (final)")
                                      : oc === "failed" ? (readyBox.rail === "safe"
                                                           ? qsTr("⚠ On-chain execution reverted — the Safe rejected it")
                                                           : qsTr("⚠ The chain rejected it"))
                                      : qsTr("Submitted — awaiting finality")) + tx;
                            }
                            color: {
                                var o = readyBox.outcome || ({});
                                return (o.error !== undefined || String(o.onchain || "") === "failed")
                                       ? Theme.palette.warning : Theme.palette.textSecondary;
                            }
                        }
                        ActionButton {
                            id: copyTx
                            objectName: "roomCopyTx"
                            property bool copied: false
                            quiet: true
                            visible: !!(readyBox.outcome && readyBox.outcome.txHash)
                            Layout.alignment: Qt.AlignTop
                            text: copied ? qsTr("✓ Copied") : qsTr("Copy hash")
                            onClicked: {
                                txClip.text = String(readyBox.outcome.txHash);
                                txClip.selectAll(); txClip.copy();
                                copied = true; copiedTimer.restart();
                            }
                            TextEdit { id: txClip; visible: false; width: 0; height: 0 }
                            Timer { id: copiedTimer; interval: 1500; onTriggered: copyTx.copied = false }
                        }
                    }

                    // honest invoke-execute outcome (executed/detail, or an error).
                    // The core never reports a false success — a gated or failed
                    // call is an error here, not a silent "ran".
                    LogosText {
                        visible: readyBox.execOutcome !== null
                        Layout.fillWidth: true
                        wrapMode: Text.WrapAnywhere
                        text: {
                            var o = readyBox.execOutcome || ({});
                            if (o.error !== undefined) {
                                var err = String(o.error);
                                if (err === "not-invoke")
                                    return qsTr("⚠ This isn't a module action, so there is nothing to run.");
                                if (err === "not-executable")
                                    return qsTr("⚠ Not ready to run — state is \"%1\".")
                                           .arg(String(o.state || ""));
                                if (err === "not-allowed")
                                    return qsTr("⚠ Blocked: %1.%2 isn't on this device's list of module "
                                             + "actions it may run, or that module refused.")
                                           .arg(String(o.module || "")).arg(String(o.method || ""));
                                return qsTr("⚠ ") + err + (o.detail ? " — " + String(o.detail) : "");
                            }
                            if (o.executed === false)
                                return qsTr("⚠ The action did not run%1").arg(o.detail ? " — " + String(o.detail) : "");
                            return o.executed
                                 ? qsTr("✓ Action ran%1").arg(o.detail ? "  ·  " + String(o.detail) : "")
                                 : qsTr("Running…");
                        }
                        color: {
                            var o = readyBox.execOutcome || ({});
                            return (o.error !== undefined) ? Theme.palette.warning
                                                           : Theme.palette.textSecondary;
                        }
                        font.family: MusterStyle.mono
                        font.pixelSize: MusterStyle.caption
                    }
                }

                // a ref the fold hasn't caught up to yet — a quiet placeholder,
                // never an invented card.
                LogosText {
                    visible: msg.isIntentRef && msg.liveIntent === null
                    Layout.fillWidth: true
                    text: qsTr("· a proposal")
                    color: Theme.palette.textTertiary
                    font.family: MusterStyle.mono
                    font.pixelSize: MusterStyle.caption
                }

                // ── a voice note (CardVoiceNote): from the row's `voice` field only ──
                // The module plays it; this thread only asks, and polls where it is.
                CardVoiceNote {
                    id: voiceCard
                    visible: msg.isVoice
                    voice: msg.voice || ({})
                    rowId: String(modelData.id || "")
                    authorName: msg.authorName
                    ts: modelData.ts || 0
                    playing: msg.isVoice && !!room.voicePlaying
                             && String(room.voicePlaying.note || "") === String((msg.voice || {}).note || "")
                    positionMs: voiceCard.playing ? Number(room.voicePlaying.positionMs || 0) : 0
                    starting: voiceCard.playing && !!room.voicePlaying.starting
                    // one stream at a time: nothing plays over a recording (or one starting)
                    // or another note
                    canPlay: (room.voiceState === "idle" || room.voiceState === "draft") && !room.voicePlaying
                    onPlayVoice: function (note) { room.playVoice(note); }
                    onStopVoice: room.stopVoicePlay()
                }

                // ── other typed cards (address-share / receipt) ────────────
                MusterCard {
                    id: otherCard
                    visible: msg.parsedCard !== null && !msg.isIntentRef && otherCard.known
                    Layout.fillWidth: true
                    card: msg.parsedCard || ({})
                    // an address-request knows who answered it, and whom it asked (exo-8e2)
                    answers: (msg.parsedCard && String(msg.parsedCard.kind || "") === "address-request")
                             ? room.addressAnswers(msg.index, msg.parsedCard) : []
                    readerIdentity: room.myIdentity
                    postedByMe: !!(msg.modelData && msg.modelData.self)
                    askedOfName: (msg.parsedCard && msg.parsedCard["for"])
                                 ? room.memberLabel(String(msg.parsedCard["for"])) : ""
                    onShareAddress: {
                        // my address on that chain is the module's to say, never this view's: on
                        // Basecamp an Ethereum one is the keystore account I pay from and am paid
                        // at, not muster's own key (exo-cb3), and the module signs the share as mine
                        if (room.backend)
                            room.backend.shareAddress(String((msg.parsedCard || {}).chain || ""));
                    }
                    // A peer disclosed an address in answer to the ask — drop it
                    // straight into the payment recipient and open the composer, so
                    // it's used as shared, never retyped.
                    onUseAddress: function(addr) {
                        room.composeType = "payment";
                        room.composing = true;
                        room.proposeTo.text = addr;
                    }
                }

                // ── plain chat text ────────────────────────────────────────
                ColumnLayout {
                    visible: msg.isText
                    Layout.fillWidth: true
                    spacing: 2

                    // who and when, once per run of lines (exo-52d); the full time on hover
                    RowLayout {
                        objectName: "messageHeader"
                        visible: !msg.continues
                        Layout.topMargin: msg.index > 0 && !msg.newDay ? Theme.spacing.small : 0
                        spacing: Theme.spacing.small
                        LogosText {
                            objectName: "messageAuthor_" + String(modelData.id || "")
                            text: msg.authorName
                            color: modelData.self ? Theme.palette.textSecondary : Theme.palette.text
                            font.pixelSize: MusterStyle.caption
                            font.weight: Theme.typography.weightBold
                        }
                        LogosText {
                            objectName: "messageTime"
                            visible: !!modelData.ts
                            text: MusterStyle.ago(modelData.ts)
                            color: Theme.palette.textTertiary
                            font.pixelSize: MusterStyle.caption
                            HoverHandler { id: timeHover }
                            LogosToolTip { visible: timeHover.hovered; text: MusterStyle.fullTime(modelData.ts) }
                        }
                    }
                    LogosText {
                        objectName: "messageText_" + String(modelData.id || "")
                        Layout.fillWidth: true
                        text: String(modelData.body || "")
                        color: modelData.pending || modelData.failed ? Theme.palette.textSecondary : Theme.palette.text
                        font.pixelSize: MusterStyle.body
                        wrapMode: Text.Wrap     // at words; a word longer than the line breaks anywhere
                    }
                    // on its way (exo-49d): the room's log hasn't returned it yet
                    RowLayout {
                        visible: !!modelData.pending || !!modelData.failed
                        spacing: Theme.spacing.small
                        LogosText {
                            objectName: modelData.failed ? "messageNotSent" : modelData.pending ? "messageSending" : ""
                            text: modelData.failed ? qsTr("Not sent") : qsTr("Sending…")
                            color: modelData.failed ? MusterStyle.warning : Theme.palette.textTertiary
                            font.pixelSize: MusterStyle.caption
                        }
                        LogosText {
                            id: retryLink
                            objectName: modelData.failed ? "messageRetry" : ""
                            signal clicked()
                            visible: !!modelData.failed
                            text: qsTr("Try again")
                            color: Theme.palette.primary
                            font.pixelSize: MusterStyle.caption
                            font.underline: retryHover.hovered
                            onClicked: room.retrySend(String(modelData.outboxKey || ""))
                            HoverHandler { id: retryHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: retryLink.clicked() }
                        }
                    }
                }
            }
        }
    }
}
