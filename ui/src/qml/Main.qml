import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// P4 — increment 2: propose → review the real re-materialization strip.
//
// ADR-011 resolved: built on Logos.Theme / Logos.Controls, so this looks like
// the rest of the platform and inherits U-10's contrast / reduced-motion.
//
// What this slice does, and does honestly:
//   • describe()  → the Safe account this walkthrough coordinates (chainId,
//                   safe, threshold) — shown, never assumed by the view.
//   • propose()   → the module canonicalizes the effect to the EIP-712
//                   safeTxHash and returns an intent id.
//   • txhash()    → those exact bytes, re-derived by the module from the effect.
//
// The strip shows the effect we sent against the hash the module re-derived from
// it. They agree by construction, which is the honest "matches" state — the
// first time this check runs against a real driver rather than the prototype's
// simulated hashes. A genuine MISMATCH is the module core's to refuse (F-4 /
// invariant 1); it only becomes demonstrable with a divergent input source (the
// plugin runtime, P5), so it is never simulated here.
//
// What this slice deliberately does NOT do: collect approvals. An approval is an
// owner signature over the safeTxHash, and the UI/core never holds keys — owners
// sign on their own devices. Collecting across owners is the multi-instance step
// (P3); until then the card stops honestly at "here are the bytes each owner
// will sign."
//
// NB: nix build does not evaluate QML — this needs qmllint against the
// design-system import path AND a launch to be believed
// (docs/labbook/qml-errors-are-invisible-to-nix-build.md).
Item {
    id: root

    readonly property var backend: logos.module("muster_ui")
    property bool ready: false

    // Whether the account card's owner list is expanded (Account view, "dive in").
    property bool ownersOpen: false

    // Which surface is showing. The product opens on "home" (the action list);
    // "compose" (create a room from an action), "room" (the conversation),
    // "dashboard" (the Safe lifecycle spike), "walkthrough" (the claims registry).
    property string view: "home"

    // Enter a room by topic: join it in the module, then show the room surface.
    function enterRoom(topic) {
        if (root.backend && topic) {
            root.backend.joinRoom(topic);
            root.view = "room";
        }
    }

    // Backend PROPs, aliased so bindings read cleanly. The backend is the only
    // writer; these are all reads.
    readonly property string health: backend ? backend.health : "(no backend)"
    readonly property bool healthy: root.health === "ok"
    readonly property string accountJson: backend ? backend.accountJson : ""
    readonly property string intentId: backend ? backend.intentId : ""
    readonly property string intentEffect: backend ? backend.intentEffect : ""
    readonly property string intentTxhash: backend ? backend.intentTxhash : ""
    readonly property string intentState: backend ? backend.intentState : ""
    readonly property string lastError: backend ? backend.lastError : ""
    readonly property string balancesJson: backend ? backend.balancesJson : "[]"

    readonly property bool hasIntent: root.intentId.length > 0

    // Still collecting signatures: show the approve affordance until the driver
    // reports the threshold met (executable) or the intent has moved on-chain.
    readonly property bool collectable: root.hasIntent
        && root.intentState !== "executable" && root.intentState !== "submitted"
        && root.intentState !== "settling" && root.intentState !== "final"

    // The post-collection legs: executable (ready to submit), submitting (on-chain,
    // awaiting the receipt), and final (executed, finality read from the chain).
    readonly property bool isExecutable: root.intentState === "executable"
    readonly property bool isSubmitting: root.intentState === "submitted" || root.intentState === "settling"
    readonly property bool isFinal: root.intentState === "final"

    // Parsed views of the JSON the module handed us. A parse failure yields null
    // rather than a guess, so a broken value renders as absent, not as fiction.
    readonly property var account: {
        try { return root.accountJson ? JSON.parse(root.accountJson) : null; }
        catch (e) { return null; }
    }
    readonly property var effect: {
        try { return root.intentEffect ? JSON.parse(root.intentEffect) : null; }
        catch (e) { return null; }
    }
    // The wallet balances, parsed. A parse failure yields [] (absent), not fiction.
    readonly property var balances: {
        try { return root.balancesJson ? JSON.parse(root.balancesJson) : []; }
        catch (e) { return []; }
    }

    // Room state, aliased for the home fold.
    readonly property string roomTopic: backend ? backend.roomTopic : ""
    readonly property string intentsJson: backend ? backend.intentsJson : "[]"

    // Every joined conversation (multi-room), from coordinate_conversations.
    readonly property var conversations: {
        try { return JSON.parse(backend ? backend.conversationsJson : "[]"); }
        catch (e) { return []; }
    }

    // The home surface lists every joined room. The ACTIVE room also folds its
    // latest intent into a headline; the rest show when they were last active.
    // Opening a row re-joins (re-activates) that room. Empty until a room exists.
    readonly property var homeActions: {
        var rows = [];
        var convs = root.conversations;
        var hl = "Talking", st = "waiting", detail = "in the room";
        try {
            var ints = JSON.parse(root.intentsJson);
            if (ints.length) {
                var last = ints[ints.length - 1];
                hl = last.state === "executable" ? "Ready to submit"
                   : last.state === "collecting" ? "Collecting approvals"
                   : last.state === "final" ? "Done" : "Proposed";
                st = last.state === "executable" ? "needs"
                   : last.state === "final" ? "settled" : "waiting";
                detail = "intent " + String(last.id || "").substring(0, 8) + " · " + last.state;
            }
        } catch (e) {}
        for (var i = 0; i < convs.length; ++i) {
            var c = convs[i];
            var topic = String(c.topic || "");
            if (c.active)
                rows.push({ topic: topic, title: topic, action: hl, state: st, detail: detail });
            else
                rows.push({ topic: topic, title: topic, action: "Open", state: "idle",
                            detail: c.lastTs ? ("last active · " + c.lastTs) : "no messages yet" });
        }
        return rows;
    }

    Connections {
        target: logos
        function onViewModuleReadyChanged(moduleName, isReady) {
            if (moduleName === "muster_ui")
                root.ready = isReady && root.backend !== null;
        }
    }
    Component.onCompleted: {
        root.ready = root.backend !== null && logos.isViewModuleReady("muster_ui");
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.palette.background
    }

    // ── top nav bar ──────────────────────────────────────────────────────
    // Occupies its own strip at the top with a solid ground, so it never overlaps
    // the surface below it. Every surface anchors under `navBar.bottom`.
    Rectangle {
        id: navBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: navRow.implicitHeight + 2 * Theme.spacing.small
        color: Theme.palette.background
        z: 10

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: Theme.palette.borderSubtle
        }

        RowLayout {
            id: navRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.rightMargin: Theme.spacing.medium
            spacing: Theme.spacing.small

            // The current surface reads as filled (Primary); the rest stay neutral
            // (Secondary), so "where am I" is answered without a second glance.
            // Compose is a sub-flow of Home, so Home stays lit through it.
            LogosButton {
                objectName: "homeToggle"; text: qsTr("Home")
                variant: (root.view === "home" || root.view === "compose")
                         ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                onClicked: {
                    root.view = "home";
                    if (root.backend) root.backend.loadConversations();   // refresh the room list
                }
            }
            LogosButton {
                objectName: "roomToggle"; text: qsTr("Room")
                variant: root.view === "room" ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                onClicked: root.view = "room"
            }
            LogosButton {
                objectName: "dashboardToggle"; text: qsTr("Account")
                variant: root.view === "dashboard" ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                onClicked: root.view = "dashboard"
            }
            LogosButton {
                objectName: "walkthroughToggle"; text: qsTr("Walkthrough")
                variant: root.view === "walkthrough" ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                onClicked: root.view = (root.view === "walkthrough" ? "home" : "walkthrough")
            }
            LogosButton {
                objectName: "settingsToggle"; text: qsTr("Settings")
                variant: root.view === "settings" ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                onClicked: {
                    root.view = "settings";
                    if (root.backend) root.backend.loadSettings();
                }
            }
        }
    }

    // ── the product surfaces (one shown at a time), below the nav bar ─────
    // Home: the action list. Opening a row joins that room; "Start something"
    // goes to the composer.
    Home {
        objectName: "homeSurface"
        anchors.top: navBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.view === "home"
        actions: root.homeActions
        onActivated: root.enterRoom(topic)
        onNewActivity: root.view = "compose"
    }

    // Compose: create a room from an action (verb → people → account).
    Composer {
        anchors.top: navBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.view === "compose"
        onCreateRoom: root.enterRoom(topic)
    }

    // The conversation surface. Reads its state from the module through the backend.
    Room {
        objectName: "roomSurface"
        anchors.top: navBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.view === "room"
        backend: root.backend
    }

    // The teaching surface (ADR-012 claims registry).
    Walkthrough {
        anchors.top: navBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.view === "walkthrough"
    }

    // The config-shell start: identity + user-configurable infrastructure (inv 8).
    Settings {
        objectName: "settingsSurface"
        anchors.top: navBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.view === "settings"
        backend: root.backend
    }

    ColumnLayout {
        id: page
        visible: root.view === "dashboard"
        anchors.top: navBar.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: Theme.spacing.large
        anchors.bottomMargin: Theme.spacing.xlarge
        spacing: Theme.spacing.large
        width: Math.min(parent.width - 2 * Theme.spacing.xlarge, 520)

        // ── header ───────────────────────────────────────────────────────────
        LogosText {
            text: qsTr("Muster")
            color: Theme.palette.text
            font.family: Theme.typography.publicSans
            font.pixelSize: Theme.typography.subtitleText
            font.weight: Theme.typography.weightBold
            Layout.alignment: Qt.AlignHCenter
        }

        LogosText {
            text: qsTr("The Safe you coordinate against — inspect it, act on it directly, "
                     + "and settle on-chain. To coordinate with people, open a Room.")
            color: Theme.palette.textTertiary
            font.pixelSize: Theme.typography.secondaryText
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth: true
        }

        // ── the Safe account being coordinated ────────────────────────────────
        // Shown from describe(); a null account renders as "not loaded", never as
        // a fabricated address.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: acctCol.implicitHeight + 2 * Theme.spacing.medium
            radius: Theme.spacing.radiusMedium
            color: Theme.palette.surface
            border.width: 1
            border.color: Theme.palette.borderSubtle

            ColumnLayout {
                id: acctCol
                anchors.fill: parent
                anchors.margins: Theme.spacing.medium
                spacing: Theme.spacing.tiny

                LogosText {
                    text: qsTr("SAFE ACCOUNT")
                    color: Theme.palette.textTertiary
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.badgeText
                    font.weight: Theme.typography.weightMedium
                }

                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.WrapAnywhere
                    text: root.account
                        ? qsTr("Safe %1").arg(String(root.account.safe))
                        : qsTr("account not loaded")
                    color: Theme.palette.text
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.secondaryText
                }

                LogosText {
                    visible: !!root.account
                    text: root.account
                        ? qsTr("%1 of %2 owners · chain %3 · %4")
                            .arg(Number(root.account.threshold))
                            .arg(root.account.owners ? root.account.owners.length : 0)
                            .arg(Number(root.account.chainId))
                            .arg(String(root.account.environment))
                        : ""
                    color: Theme.palette.textSecondary
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.badgeText
                }

                // ── owners (dive in) ─────────────────────────────────────────
                // The approval policy is who can sign, so the owner addresses are
                // worth seeing — collapsed to a count by default, the full list a
                // tap away. Any 2 of these signing meets the threshold above.
                Item {
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.spacing.tiny
                    implicitHeight: ownersToggle.implicitHeight
                    visible: !!root.account && !!root.account.owners
                             && root.account.owners.length > 0

                    LogosText {
                        id: ownersToggle
                        text: root.ownersOpen
                            ? qsTr("Owners — tap to hide  −")
                            : qsTr("Owners — tap to see all %1  +")
                                .arg(root.account && root.account.owners ? root.account.owners.length : 0)
                        color: Theme.palette.textSecondary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.ownersOpen = !root.ownersOpen
                    }
                }

                Repeater {
                    model: (root.ownersOpen && root.account && root.account.owners)
                           ? root.account.owners : []

                    delegate: LogosText {
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.leftMargin: Theme.spacing.small
                        wrapMode: Text.WrapAnywhere
                        text: "· " + String(modelData)
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                    }
                }
            }
        }

        // ── propose composer ──────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: composeCol.implicitHeight + 2 * Theme.spacing.medium
            radius: Theme.spacing.radiusMedium
            color: Theme.palette.surface
            border.width: 1
            border.color: Theme.palette.borderDefault

            ColumnLayout {
                id: composeCol
                anchors.fill: parent
                anchors.margins: Theme.spacing.medium
                spacing: Theme.spacing.small

                LogosText {
                    text: qsTr("Propose a transfer — directly")
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.primaryText
                    font.weight: Theme.typography.weightMedium
                }

                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: qsTr("The direct path: you drive the whole lifecycle here — propose, "
                             + "collect signatures, settle on-chain. To decide it with people in "
                             + "a conversation instead, open a Room.")
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.badgeText
                }

                LogosTextField {
                    id: toField
                    objectName: "proposeTo"
                    Layout.fillWidth: true
                    placeholderText: qsTr("to (0x…)")
                    font.family: Theme.typography.mono
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosTextField {
                        id: valueField
                        objectName: "proposeValue"
                        Layout.fillWidth: true
                        placeholderText: qsTr("value")
                        font.family: Theme.typography.mono
                        validator: IntValidator { bottom: 0 }
                    }

                    LogosTextField {
                        id: nonceField
                        objectName: "proposeNonce"
                        Layout.preferredWidth: 120
                        placeholderText: qsTr("nonce")
                        font.family: Theme.typography.mono
                        validator: IntValidator { bottom: 0 }
                    }
                }

                LogosButton {
                    objectName: "proposeButton"
                    Layout.fillWidth: true
                    variant: LogosButton.Variant.Primary
                    text: qsTr("Propose")
                    enabled: root.ready && toField.text.length > 0 && valueField.text.length > 0
                    onClicked: {
                        if (!root.backend)
                            return;
                        var effectJson = JSON.stringify({
                            to: toField.text,
                            value: parseInt(valueField.text || "0", 10),
                            nonce: parseInt(nonceField.text || "0", 10)
                        });
                        root.backend.propose(effectJson);
                    }
                }
            }
        }

        // ── the intent, once proposed ─────────────────────────────────────────
        Rectangle {
            objectName: "intentCard"
            Layout.fillWidth: true
            visible: root.hasIntent
            implicitHeight: intentCol.implicitHeight + 2 * Theme.spacing.medium
            radius: Theme.spacing.radiusMedium
            color: Theme.palette.surfaceRaised
            border.width: 1
            border.color: Theme.palette.borderDefault

            ColumnLayout {
                id: intentCol
                anchors.fill: parent
                anchors.margins: Theme.spacing.medium
                spacing: Theme.spacing.small

                // The effect, in plain terms: amount leads, destination follows.
                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.WrapAnywhere
                    text: root.effect
                        ? qsTr("%1 → %2").arg(String(root.effect.value)).arg(String(root.effect.to))
                        : root.intentId
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.primaryText
                    font.weight: Theme.typography.weightMedium
                }

                LogosText {
                    text: qsTr("%1 · nonce %2")
                        .arg(root.intentId)
                        .arg(root.effect && root.effect.nonce !== undefined ? String(root.effect.nonce) : "0")
                    color: Theme.palette.textTertiary
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.badgeText
                }

                // ── status rail ──────────────────────────────────────────────
                // The full lifecycle path, drawn from the first card so it is
                // visible where a proposal has got to. This build reaches
                // "executable" (the threshold is a driver fact); submitted/final
                // arrive with the submit method (next increment) and stay unlit.
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.spacing.tiny
                    spacing: Theme.spacing.small

                    Repeater {
                        model: [{ k: "proposed", t: qsTr("proposed") },
                                { k: "collecting", t: qsTr("collecting") },
                                { k: "executable", t: qsTr("ready") },
                                { k: "submitted", t: qsTr("submitted") },
                                { k: "final", t: qsTr("final") }]

                        delegate: RowLayout {
                            id: step
                            required property var modelData
                            required property int index
                            spacing: 4

                            readonly property string current:
                                root.intentState === "draft" ? "proposed" : root.intentState
                            readonly property bool lit:
                                step.index <= ["proposed", "collecting", "executable", "submitted", "final"]
                                    .indexOf(step.current)

                            Rectangle {
                                implicitWidth: 6
                                implicitHeight: 6
                                radius: 3
                                color: step.lit ? Theme.palette.success : Theme.palette.borderDefault
                            }

                            LogosText {
                                text: step.modelData.t
                                color: step.lit ? Theme.palette.textSecondary : Theme.palette.textTertiary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                            }
                        }
                    }
                }

                // ── the re-materialization strip ─────────────────────────────
                // The point of the whole slice. "re-derived" is the module's real
                // EIP-712 safeTxHash, computed from the effect shown — not a value
                // a service asserted. Shown and re-derived agree by construction,
                // which is the honest match. If they ever disagreed, the module
                // core refuses to sign (F-4 / invariant 1) — that refusal is real
                // and lives below the UI; it is never faked here.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.spacing.tiny
                    implicitHeight: stripCol.implicitHeight + 2 * Theme.spacing.small
                    radius: Theme.spacing.radiusSmall
                    color: Theme.palette.surfaceRecessed
                    border.width: 1
                    border.color: Theme.palette.success

                    ColumnLayout {
                        id: stripCol
                        anchors.fill: parent
                        anchors.margins: Theme.spacing.small
                        spacing: Theme.spacing.tiny

                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: qsTr("✓ your client re-derived this — these are the exact bytes each owner signs")
                            color: Theme.palette.success
                            font.pixelSize: Theme.typography.secondaryText
                            font.weight: Theme.typography.weightMedium
                        }

                        // shown / re-derived / domain, in mono.
                        Repeater {
                            model: [
                                { k: qsTr("shown"),
                                  v: root.effect
                                     ? qsTr("%1 → %2 · nonce %3")
                                        .arg(String(root.effect.value))
                                        .arg(String(root.effect.to))
                                        .arg(root.effect.nonce !== undefined ? String(root.effect.nonce) : "0")
                                     : root.intentEffect },
                                { k: qsTr("re-derived"), v: root.intentTxhash },
                                { k: qsTr("domain"),
                                  v: root.account
                                     ? qsTr("chain %1 · Safe %2")
                                        .arg(Number(root.account.chainId)).arg(String(root.account.safe))
                                     : qsTr("committed inside the hash") }
                            ]

                            delegate: RowLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: Theme.spacing.small

                                LogosText {
                                    Layout.preferredWidth: 72
                                    text: modelData.k
                                    color: Theme.palette.textTertiary
                                    font.family: Theme.typography.mono
                                    font.pixelSize: Theme.typography.badgeText
                                }

                                LogosText {
                                    Layout.fillWidth: true
                                    wrapMode: Text.WrapAnywhere
                                    text: modelData.v
                                    color: Theme.palette.textSecondary
                                    font.family: Theme.typography.mono
                                    font.pixelSize: Theme.typography.badgeText
                                }
                            }
                        }
                    }
                }

                // ── collect owner signatures ─────────────────────────────────
                // The client holds no keys: each owner signs the exact bytes above
                // on their own device and hands back the signature. Paste one here
                // to collect it; the module verifies it recovers to a configured
                // owner before it counts toward the threshold (F-5). When the
                // threshold is met the driver reports the intent executable.
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.spacing.tiny
                    visible: root.collectable
                    spacing: Theme.spacing.small

                    LogosTextField {
                        id: sigField
                        objectName: "approveSig"
                        Layout.fillWidth: true
                        placeholderText: qsTr("paste an owner signature (65-byte hex)")
                        font.family: Theme.typography.mono
                    }

                    LogosButton {
                        objectName: "approveButton"
                        Layout.fillWidth: true
                        variant: LogosButton.Variant.Primary
                        text: qsTr("Add signature")
                        enabled: root.ready && sigField.text.length > 0
                        onClicked: {
                            if (root.backend)
                                root.backend.approve(sigField.text);
                            sigField.text = "";
                        }
                    }

                    LogosText {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("Each owner signs on their own device — the client never holds their keys. "
                                 + "%1 of %2 owners must sign; a signature counts only if it recovers to an owner.")
                            .arg(root.account ? Number(root.account.threshold) : 2)
                            .arg(root.account && root.account.owners ? root.account.owners.length : 3)
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }
                }

                // ── executable → submit → final ──────────────────────────────
                // The signatures are collected; the module can now assemble the
                // Safe execTransaction and send it through the user's RPC. Finality
                // is read from the receipt (R-8), never asserted by a service.
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.spacing.tiny
                    visible: root.hasIntent && !root.collectable
                    spacing: Theme.spacing.small

                    LogosText {
                        objectName: "executableNotice"
                        Layout.fillWidth: true
                        visible: root.isExecutable
                        wrapMode: Text.WordWrap
                        text: qsTr("✓ threshold met — the owner signatures are collected. Submit assembles the Safe execTransaction and sends it through your RPC.")
                        color: Theme.palette.success
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }

                    LogosButton {
                        objectName: "submitButton"
                        Layout.fillWidth: true
                        visible: root.isExecutable
                        variant: LogosButton.Variant.Primary
                        text: qsTr("Submit on-chain")
                        enabled: root.ready
                        onClicked: {
                            if (root.backend)
                                root.backend.submit();
                        }
                    }

                    LogosText {
                        Layout.fillWidth: true
                        visible: root.isSubmitting
                        wrapMode: Text.WordWrap
                        text: qsTr("submitting… waiting for the receipt")
                        color: Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.badgeText
                    }

                    LogosText {
                        objectName: "finalNotice"
                        Layout.fillWidth: true
                        visible: root.isFinal
                        wrapMode: Text.WordWrap
                        text: qsTr("✓ executed on-chain — final. The transfer settled through the Safe; finality was read from the chain, not asserted by a service.")
                        color: Theme.palette.success
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }

                    LogosButton {
                        objectName: "newProposalButton"
                        Layout.fillWidth: true
                        visible: root.isFinal
                        text: qsTr("Start a new proposal")
                        onClicked: { if (root.backend) root.backend.reset(); }
                    }
                }
            }
        }

        // ── error banner ──────────────────────────────────────────────────────
        // One place for every failure — a rejected signature, an unreachable RPC,
        // a failed proposal. It clears when the next action runs (each backend call
        // resets it), or on New proposal. Honest by construction: the text is the
        // module's own reason, never a guess.
        Rectangle {
            objectName: "errorBanner"
            Layout.fillWidth: true
            visible: root.lastError.length > 0
            implicitHeight: errRow.implicitHeight + 2 * Theme.spacing.medium
            radius: Theme.spacing.radiusSmall
            color: Theme.palette.surface
            border.width: 1
            border.color: Theme.palette.error

            RowLayout {
                id: errRow
                anchors.fill: parent
                anchors.margins: Theme.spacing.medium
                spacing: Theme.spacing.small

                LogosText {
                    objectName: "errorText"
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: root.lastError
                    color: Theme.palette.error
                    font.pixelSize: Theme.typography.badgeText
                }

                // Recovery from any error — including a submit that never landed.
                LogosButton {
                    objectName: "errorResetButton"
                    visible: root.hasIntent
                    text: qsTr("New proposal")
                    onClicked: { if (root.backend) root.backend.reset(); }
                }
            }
        }

        // ── wallet: balances across chains, each with its F-10 grade badge ────
        // The account-level view. A balance is shown with a badge saying whether
        // it is "verified" (checked against a consensus state root) or "attested"
        // (what the RPC returned, trusted) — the honesty rule made visible. A read
        // that could not be answered shows "unavailable", never a false zero.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: walletCol.implicitHeight + 2 * Theme.spacing.medium
            radius: Theme.spacing.radiusMedium
            color: Theme.palette.surface
            border.width: 1
            border.color: Theme.palette.borderSubtle

            ColumnLayout {
                id: walletCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.spacing.medium
                spacing: Theme.spacing.small

                LogosText {
                    text: qsTr("WALLET")
                    color: Theme.palette.textTertiary
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.badgeText
                    font.weight: Theme.typography.weightMedium
                }

                Repeater {
                    model: root.balances
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small

                        LogosText {
                            text: (modelData.asset || "?") + "  " + (modelData.chain || "")
                            color: Theme.palette.text
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.secondaryText
                        }
                        Item { Layout.fillWidth: true }
                        LogosText {
                            text: modelData.error ? qsTr("unavailable") : (modelData.display || "")
                            color: modelData.error ? Theme.palette.warning : Theme.palette.text
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.secondaryText
                        }
                        Rectangle {
                            visible: !modelData.error
                            implicitWidth: gradeText.implicitWidth + 2 * Theme.spacing.small
                            implicitHeight: gradeText.implicitHeight + Theme.spacing.tiny
                            radius: Theme.spacing.radiusMedium
                            color: modelData.grade === "verified-locally"
                                   ? Theme.palette.success : Theme.palette.warning
                            LogosText {
                                id: gradeText
                                anchors.centerIn: parent
                                text: modelData.grade === "verified-locally"
                                      ? qsTr("verified") : qsTr("attested")
                                color: Theme.palette.background
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                                font.weight: Theme.typography.weightMedium
                            }
                        }
                    }
                }

                LogosText {
                    visible: root.balances.length === 0
                    text: qsTr("no balances yet")
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.badgeText
                }

                LogosButton {
                    Layout.fillWidth: true
                    variant: LogosButton.Variant.Primary
                    text: qsTr("Refresh balances")
                    onClicked: root.backend.loadBalances()
                }
            }
        }

        // ── health footer (the loading-spike smoke test, kept) ────────────────
        RowLayout {
            Layout.topMargin: Theme.spacing.small
            Layout.alignment: Qt.AlignHCenter
            spacing: Theme.spacing.small

            Rectangle {
                implicitWidth: 8
                implicitHeight: 8
                radius: 4
                color: root.ready ? (root.healthy ? Theme.palette.success : Theme.palette.warning)
                                   : Theme.palette.warning
            }

            LogosText {
                text: root.ready ? qsTr("module.health() → %1").arg(root.health)
                                 : qsTr("connecting to backend…")
                color: Theme.palette.textTertiary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
            }
        }
    }
}
