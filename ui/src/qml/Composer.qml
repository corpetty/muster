import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// F-18 — create a room from an action. Two steps: WHAT you're doing together, then
// WHO with. The action comes first because everything after it is scoped by that
// choice; a chat app asks "one person or a group?" first and makes you pick a
// container before you have said what it is for. Muster is a coordination client,
// not a payments app — a payment is one action among others (a decision, a
// conversation), and the coordination MECHANISM (the driver) follows from the action
// rather than being a jargon step the user must reason about.
//
// PURE-RENDER: this view calls no backend. It emits createRoom(verb, peer, topic,
// policy) when the user confirms and lets the host wire that to the module — `policy`
// is the driver the chosen action implies. The topic is derived here so the room
// opens knowing what it is for.
//
// NB (ADR-011): nix build does not evaluate QML — a QML error blanks the whole
// view and is invisible to the build. This restricts itself to Theme keys and
// the Logos.Controls types Main.qml already uses (LogosText, LogosButton,
// LogosTextField); everything is guarded.
Item {
    id: composer

    // Fired when the user confirms. The host opens the room from these — and sets it
    // to coordinate under `policy` (the driver the intent runs on). `draftJson` is the
    // first intent to propose once the room opens (the F-18 third step: account + asset
    // + destination), or "" when there is nothing to draft (decide / talk, or a pay with
    // an empty amount) — exo-45e K6/exo-fa1.
    signal createRoom(string verb, string peer, string topic, string policy, string draftJson)

    // "" until an action is picked. Drives the progressive reveal.
    property string pickedVerb: ""

    // The address book (from the host): [{identity, alias, address}] — so "who with"
    // can be a tap on a name rather than a pasted id.
    property var contacts: []

    // The backend (from Main), so the third step can ask compose_offers which of my
    // holdings fill the proposer slots — the asset+amount I can send (exo-45e K6). Null
    // in isolation: the third step then just shows the fields, no candidate list.
    property var backend: null
    // The F-18 third step's picks (for the "pay" verb): the asset, the amount, and the
    // destination — or "ask the room" for the destination (the counterparty request path).
    property string pickedAsset: ""
    property string destination: ""
    property bool askRoom: false
    readonly property string amount: amountField ? amountField.text.trim() : ""

    // compose_offers for the current draft: {ready, offers:[{requirement, status,
    // candidates:[{public, class, form, grade, discloses}]}]} — the proposer slots and
    // which of my holdings fill them. Refreshed when the third step opens.
    readonly property var composeOffers: {
        try { return JSON.parse(composer.backend ? composer.backend.composeOffersJson : "{}"); }
        catch (e) { return ({}); }
    }
    // The asset candidates (an asset-class proposer slot's candidates), for the picker.
    function assetCandidates() {
        var o = composer.composeOffers;
        if (!o || !o.offers) return [];
        for (var i = 0; i < o.offers.length; ++i)
            if (o.offers[i].requirement && o.offers[i].requirement.kind === "asset")
                return o.offers[i].candidates || [];
        return [];
    }
    // Ask the module which of my holdings fill a draft payment's proposer slots.
    function refreshComposeOffers() {
        if (!composer.backend) return;
        var draft = { to: composer.destination, value: Number(composer.amount) || 0, nonce: 0 };
        composer.backend.loadComposeOffers(JSON.stringify(draft));
    }
    // The draft first intent, or "" when there is nothing to propose on open.
    function draftJson() {
        if (composer.pickedVerb !== "pay") return "";
        if (composer.amount.length === 0) return "";           // no amount → open empty, compose in-room
        if (composer.askRoom) return "";                        // destination requested → the room fills it
        if (composer.destination.length === 0) return "";
        return JSON.stringify({ to: composer.destination, value: Number(composer.amount) || 0, nonce: 0 });
    }

    // The things a room can do together. Each carries the driver it runs on, so the
    // user picks an ACTION, not a policy — the coordination mechanism follows from
    // what you're doing (a payment settles on a Safe; a decision is a group
    // endorsement) and stays changeable in the room. Muster is a coordination client,
    // not a payments app: money is one of the things you can do together, not the frame.
    readonly property var verbs: [
        { id: "decide", proposal: "statement", name: qsTr("Decide something together"),
          note: qsTr("The room agrees on something — a k-of-n group sign-off. No chain, nothing on a public ledger; just the people who agreed.") },
        { id: "pay",    proposal: "payment",   name: qsTr("Send a payment"),
          note: qsTr("Money moves from a shared account, coordinated by the room. Each person's address stays in the room — the transaction is signed off together.") },
        { id: "talk",   proposal: "statement", name: qsTr("Just talk"),
          note: qsTr("A private conversation. Only the people in the room can read it — the room is the boundary.") }
    ]

    // The driver the room runs on follows from the chosen action, never a separate
    // jargon step: the first founding kind that serves the verb's proposal, read from the
    // module's one kind list (coordinate_drivers, exo-a50.1.2). Changeable later from the
    // room's policy row. "" until the list is loaded — the room then coheres the policy.
    readonly property string pickedPolicy: {
        var proposal = "";
        var vs = composer.verbs;
        for (var i = 0; i < vs.length; i++)
            if (vs[i].id === composer.pickedVerb) proposal = String(vs[i].proposal);
        var ks = [];
        try { ks = JSON.parse(composer.backend ? composer.backend.driversJson : "[]"); } catch (e) { ks = []; }
        if (!Array.isArray(ks)) return "";
        for (var j = 0; j < ks.length; j++)
            if (ks[j] && ks[j].founding && (ks[j].composes || []).indexOf(proposal) >= 0)
                return String(ks[j].kind);
        return "";
    }

    readonly property string peer: peerField ? peerField.text.trim() : ""
    readonly property bool hasVerb: composer.pickedVerb.length > 0
    readonly property bool hasPeer: composer.peer.length > 0
    readonly property int scopeCount: 1 + (composer.hasPeer ? 1 : 0)

    // "muster." + verb + "." + a short suffix off the peer, or just the verb solo.
    function derivedTopic() {
        if (!composer.hasVerb)
            return "";
        if (composer.hasPeer) {
            var bare = composer.peer.replace(/^0x/i, "");
            var suffix = bare.substring(Math.max(0, bare.length - 6)).toLowerCase();
            if (suffix.length === 0)
                suffix = "room";
            return "muster." + composer.pickedVerb + "." + suffix;
        }
        return "muster." + composer.pickedVerb;
    }

    // The button names the next missing choice rather than going flat and silent.
    readonly property string confirmLabel: {
        if (!composer.hasVerb)
            return qsTr("Pick an activity");
        if (composer.hasPeer)
            return qsTr("Open the room with them");
        return qsTr("Open the room — just you");
    }

    function confirm() {
        if (!composer.hasVerb)
            return;
        // Every "Start something" opens a NEW conversation, so give the topic a unique
        // tail. Without it, two rooms of the same shape — e.g. two solo "pay" rooms —
        // derive the identical topic, and coordinate_join re-activates the first
        // instead of creating a second. Re-opening an existing room goes through Home
        // (which passes its stored topic), never here, so this only affects creation.
        var uniq = Date.now().toString(36) + Math.floor(Math.random() * 46656).toString(36);
        composer.createRoom(composer.pickedVerb, composer.peer,
                            composer.derivedTopic() + "." + uniq, composer.pickedPolicy,
                            composer.draftJson());
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: stack.implicitHeight + 2 * Theme.spacing.xlarge
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: stack
            y: Theme.spacing.xlarge
            x: (flick.width - width) / 2
            width: Math.min(flick.width - 2 * Theme.spacing.xlarge, 560)
            spacing: Theme.spacing.large

            LogosText {
                text: qsTr("Start something")
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.subtitleText
                font.weight: Theme.typography.weightBold
            }

            // ── 1. what ───────────────────────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small

                LogosText {
                    text: qsTr("What are we doing together?")
                    color: Theme.palette.text
                    font.family: Theme.typography.publicSans
                    font.pixelSize: Theme.typography.primaryText
                    font.weight: Theme.typography.weightBold
                }

                Repeater {
                    model: composer.verbs

                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool picked: composer.pickedVerb === modelData.id

                        Layout.fillWidth: true
                        implicitHeight: verbCol.implicitHeight + 2 * Theme.spacing.medium
                        radius: Theme.spacing.radiusMedium
                        color: picked ? Theme.palette.surfaceRaised : Theme.palette.surface
                        border.width: picked ? 2 : 1
                        border.color: picked ? Theme.palette.primary : Theme.palette.borderSubtle

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: composer.pickedVerb = modelData.id
                        }

                        ColumnLayout {
                            id: verbCol
                            anchors.fill: parent
                            anchors.margins: Theme.spacing.medium
                            spacing: Theme.spacing.tiny

                            LogosText {
                                text: modelData.name
                                color: Theme.palette.text
                                font.family: Theme.typography.publicSans
                                font.pixelSize: Theme.typography.primaryText
                                font.weight: Theme.typography.weightMedium
                            }
                            LogosText {
                                Layout.fillWidth: true
                                text: modelData.note
                                color: Theme.palette.textTertiary
                                font.pixelSize: Theme.typography.secondaryText
                                wrapMode: Text.WordWrap
                            }
                        }
                    }
                }
            }

            // ── 2. who ────────────────────────────────────────────────────────
            ColumnLayout {
                visible: composer.hasVerb
                Layout.fillWidth: true
                spacing: Theme.spacing.small

                LogosText {
                    text: qsTr("Who's doing it with you?")
                    color: Theme.palette.text
                    font.family: Theme.typography.publicSans
                    font.pixelSize: Theme.typography.primaryText
                    font.weight: Theme.typography.weightBold
                }

                LogosTextField {
                    id: peerField
                    objectName: "composerPeerField"
                    Layout.fillWidth: true
                    placeholderText: qsTr("paste their chat id (leave empty for just you)")
                }

                // …or tap a name from your address book instead of pasting.
                LogosText {
                    visible: (composer.contacts || []).length > 0
                    text: qsTr("or pick from your contacts")
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.badgeText
                }
                Flow {
                    Layout.fillWidth: true
                    visible: (composer.contacts || []).length > 0
                    spacing: Theme.spacing.small
                    Repeater {
                        model: composer.contacts
                        delegate: Rectangle {
                            required property var modelData
                            radius: Theme.spacing.radiusSmall
                            color: Theme.palette.surface
                            border.width: 1
                            border.color: Theme.palette.borderSubtle
                            implicitWidth: chipText.implicitWidth + 2 * Theme.spacing.medium
                            implicitHeight: chipText.implicitHeight + Theme.spacing.small
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: peerField.text = String(modelData.identity || "")
                            }
                            LogosText {
                                id: chipText
                                anchors.centerIn: parent
                                text: String(modelData.alias || "").length > 0
                                      ? String(modelData.alias)
                                      : String(modelData.identity || "").substring(0, 10) + "…"
                                color: Theme.palette.textSecondary
                                font.pixelSize: Theme.typography.badgeText
                            }
                        }
                    }
                }

                LogosText {
                    Layout.fillWidth: true
                    text: qsTr("Only these people can read the room. Add someone later and they see the thread from that point forward.")
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.secondaryText
                    wrapMode: Text.WordWrap
                }
            }

            // The mechanism (the driver) follows from the action above — a payment
            // settles on a Safe, a decision is a group endorsement — so there is no
            // separate "pick a policy" step here. A one-line reassurance names it, and
            // the room's policy row lets anyone change it later.
            ColumnLayout {
                visible: composer.hasVerb
                Layout.fillWidth: true
                spacing: Theme.spacing.small

                LogosText {
                    Layout.fillWidth: true
                    text: composer.pickedPolicy === "safe"
                          ? qsTr("This settles on a shared Safe — signed off by the room, on-chain. You can change how the room approves once you're in it.")
                          : qsTr("This is a group endorsement — the room signs off, nothing touches a chain. You can change how the room approves once you're in it.")
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.secondaryText
                    wrapMode: Text.WordWrap
                }
            }

            // ── 3. account + asset/amount + destination (F-18 third step, "pay" only) ──
            // The account is the room's shared Safe; the asset+amount come from MY holdings
            // (compose_offers); the destination I type, or ask the room to fill (the
            // counterparty request path). Everything is optional — leave it blank to open
            // the room and compose the first payment inside it.
            ColumnLayout {
                visible: composer.pickedVerb === "pay"
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                onVisibleChanged: if (visible) composer.refreshComposeOffers()

                LogosText {
                    text: qsTr("What to send (optional)")
                    color: Theme.palette.text
                    font.family: Theme.typography.publicSans
                    font.pixelSize: Theme.typography.primaryText
                    font.weight: Theme.typography.weightMedium
                }
                LogosText {
                    Layout.fillWidth: true
                    text: qsTr("From the room's shared account, signed off together. Pick what you hold; leave it blank to sort it out in the room.")
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.secondaryText
                    wrapMode: Text.WordWrap
                }

                // the asset picker — my holdings (compose_offers); nothing scored, grade shown.
                Flow {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    Repeater {
                        model: composer.assetCandidates()
                        delegate: LogosButton {
                            required property var modelData
                            objectName: "assetCandidate"
                            text: String(modelData["public"]) + " (" + String(modelData.grade) + ")"
                            variant: composer.pickedAsset === String(modelData["public"])
                                     ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                            onClicked: composer.pickedAsset = String(modelData["public"])
                        }
                    }
                }
                LogosText {
                    visible: composer.assetCandidates().length === 0
                    text: qsTr("(no holdings to send from this account yet)")
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.badgeText
                }

                LogosTextField {
                    id: amountField
                    Layout.fillWidth: true
                    placeholderText: qsTr("amount (in base units)")
                    onTextChanged: composer.refreshComposeOffers()
                }

                // the destination — typed, or asked of the room (the counterparty request).
                LogosTextField {
                    Layout.fillWidth: true
                    enabled: !composer.askRoom
                    placeholderText: composer.askRoom ? qsTr("the room will ask them for it")
                                                      : qsTr("send to (address)")
                    onTextChanged: composer.destination = text
                }
                LogosButton {
                    objectName: "askRoomToggle"
                    text: composer.askRoom ? qsTr("✓ ask the room for the address")
                                           : qsTr("ask the room for the address instead")
                    variant: LogosButton.Variant.Secondary
                    onClicked: composer.askRoom = !composer.askRoom
                }
            }

            // ── footer ────────────────────────────────────────────────────────
            LogosText {
                Layout.fillWidth: true
                text: qsTr("%1 people can read this. Nobody else.").arg(composer.scopeCount)
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.secondaryText
                wrapMode: Text.WordWrap
            }

            LogosButton {
                objectName: "openRoomButton"
                Layout.fillWidth: true
                text: composer.confirmLabel
                enabled: composer.hasVerb
                onClicked: composer.confirm()
            }
        }
    }
}
