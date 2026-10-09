import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The settings surface — the start of the config shell (vision § "The end state",
// layer 1). It shows this module's identity and the *user-configurable* infra it
// points at: the RPC endpoint the wallet/Safe path reads against, and the delivery
// createNode config the next room join boots with. Invariant 8 says the store nodes
// and RPC are untrusted, user-chosen infrastructure — which is empty if the user
// can't configure it, so here it is configurable. In-memory today; the real home is
// inside basecamp, reading identity/wallet/settings from the platform (the shell we
// don't rebuild). Full identity/wallet/plugin *management* is that platform's job.
//
// PURE-RENDER: reads settingsJson from the backend, and the only things that leave
// are setSetting(key, value) calls. Its only state is which endpoint URLs are shown
// whole (the show* flags below), and that never leaves the view.
//
// NB (ADR-011): nix build does not evaluate QML; a bad type here blanks the view.
// Restricted to Theme keys + the Logos.Controls types Main.qml already proves.
Item {
    id: settings

    property var backend
    property string manageNote: ""   // what the keystore app hand-off answered (exo-d4d.2)
    property string chainNote: ""    // what the chain settings hand-off answered (exo-d4d.6)

    readonly property var s: {
        try { return JSON.parse(backend ? backend.settingsJson : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property var identity: (settings.s && settings.s.identity) ? settings.s.identity : ({})

    // A hosted endpoint's URL may carry its key (a /v3/<key> path) or user:pass@. Each one
    // shows masked (scheme://host:port, *** for the rest, as the module's redactUrl gives
    // it) until its Show is pressed, so a glance or a shared screen does not carry it
    // (exo-14f.2). View state only: it resets when the view does.
    property bool showRpc: false
    property bool showBtcRpc: false
    property bool showLezRpc: false

    // This node's RLN membership row (rln_status, exo-eb6.3): {level, detail, remedy?,
    // payer?, balance?}; {} until the first read lands, which renders as "checking…".
    readonly property var rln: {
        try { return JSON.parse(backend ? backend.rlnStatusJson : "{}") || ({}); }
        catch (e) { return ({}); }
    }
    // read while the view is open: the module answers at once (its chain reads are async)
    Timer {
        interval: 5000
        repeat: true
        triggeredOnStart: true
        running: settings.visible && !!settings.backend
        onTriggered: settings.backend.loadRlnStatus()
    }

    // This node's mix row (mix_status, exo-dcc.4), from the connectivity rows: present
    // only while the node's sends are asked to ride the mixnet; {} otherwise.
    readonly property var mix: {
        try {
            var rows = (JSON.parse(backend ? backend.connectivityJson : "{}") || ({})).rows || [];
            for (var i = 0; i < rows.length; i++) if (rows[i].key === "mix") return rows[i];
        } catch (e) {}
        return ({});
    }
    Timer {
        interval: 5000
        repeat: true
        triggeredOnStart: true
        running: settings.visible && !!settings.backend
        onTriggered: settings.backend.loadConnectivity()
    }

    // The official EVM keystore row (keystore_status, exo-149.1 K1): {level, detail,
    // remedy?, identity?, approvers, accounts:[{address, label, wallet}]}; {} until the
    // first read lands. keystore_module holds the EVM keys; muster only asks.
    // The account link waits on the Logos Signer (exo-dcc.27). Main passes where its
    // request stands, the signer's package and what installing it answered.
    property var keystoreRequests: ({})
    property string signerPackage: "evm_signer_ui"
    property var signerInstall: ({})
    signal openSignerRequested(string handle)
    signal signerInstallRequested()
    // the latest link request for the selected account: { handle, state, ... } or null
    readonly property var bindingRequest: {
        var sel = String(settings.keystore.selected || "").toLowerCase();
        var rs = (settings.keystoreRequests && settings.keystoreRequests.requests) || [];
        var last = null;
        for (var i = 0; i < rs.length; ++i)
            if (rs[i].kind === "binding" && String(rs[i].account || "").toLowerCase() === sel) last = rs[i];
        return last;
    }
    readonly property bool bindingWaiting: !!settings.bindingRequest
        && (settings.bindingRequest.state === "waiting" || settings.bindingRequest.state === "shown")
    readonly property var keystore: {
        try { return JSON.parse(backend ? backend.keystoreStatusJson : "{}") || ({}); }
        catch (e) { return ({}); }
    }
    Timer {
        interval: 5000
        repeat: true
        triggeredOnStart: true
        running: settings.visible && !!settings.backend
        onTriggered: settings.backend.loadKeystoreStatus()
    }

    // The shareable chat id: the 64-byte encryption identity (ed25519 ++ x25519) that
    // coordinate_admit takes — exactly what someone needs to add you to a room. The
    // three keys are shown separately below; this is the one string you hand out.
    readonly property string chatId: {
        var ed = String((settings.identity && settings.identity.ed25519) || "").replace(/^0x/i, "");
        var x  = String((settings.identity && settings.identity.x25519) || "").replace(/^0x/i, "");
        return (ed.length > 0 && x.length > 0) ? (ed + x) : "";
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: col.implicitHeight + 2 * Theme.spacing.xlarge
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: col
            y: Theme.spacing.xlarge
            x: (flick.width - width) / 2
            width: Math.min(flick.width - 2 * Theme.spacing.xlarge, 560)
            spacing: Theme.spacing.large

            LogosText {
                text: qsTr("Settings")
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.subtitleText
                font.weight: Theme.typography.weightBold
            }

            // ── identity ──────────────────────────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: idCol.implicitHeight + 2 * Theme.spacing.medium
                radius: Theme.spacing.radiusMedium
                color: Theme.palette.surface
                border.width: 1
                border.color: Theme.palette.borderSubtle

                ColumnLayout {
                    id: idCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.spacing.medium
                    spacing: Theme.spacing.tiny

                    LogosText {
                        text: qsTr("IDENTITY")
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }

                    Repeater {
                        model: [
                            { k: qsTr("address"), v: String((settings.identity && settings.identity.address) || "") },
                            { k: qsTr("ed25519"), v: String((settings.identity && settings.identity.ed25519) || "") },
                            { k: qsTr("x25519"),  v: String((settings.identity && settings.identity.x25519) || "") }
                        ]
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small

                            LogosText {
                                Layout.preferredWidth: 70
                                Layout.alignment: Qt.AlignTop
                                text: modelData.k
                                color: Theme.palette.textTertiary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                            }
                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.WrapAnywhere
                                text: modelData.v.length > 0 ? modelData.v : qsTr("(not loaded)")
                                color: Theme.palette.textSecondary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                            }
                        }
                    }

                    // ── your shareable chat id ────────────────────────────────
                    LogosText {
                        Layout.topMargin: Theme.spacing.small
                        text: qsTr("YOUR CHAT ID")
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }
                    LogosText {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("Share this so someone can add you to a room. It's your two encryption keys as one string — paste it to them, or into the composer.")
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        // Read-only + selectByMouse so the id can be HIGHLIGHTED (drag to
                        // select, Ctrl-C) as well as copied by the button — the two things
                        // that were missing. Styled to match the mono key rows above.
                        TextEdit {
                            id: chatIdField
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            readOnly: true
                            selectByMouse: true
                            wrapMode: TextEdit.WrapAnywhere
                            text: settings.chatId.length > 0 ? settings.chatId : qsTr("(not loaded)")
                            color: Theme.palette.textSecondary
                            selectionColor: Theme.palette.primary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }
                        LogosButton {
                            objectName: "copyChatId"
                            text: qsTr("Copy")
                            enabled: settings.chatId.length > 0
                            onClicked: { chatIdField.selectAll(); chatIdField.copy(); }
                        }
                    }

                    // ── your Bitcoin key (exo-59c) ─────────────────────────────
                    LogosText {
                        Layout.topMargin: Theme.spacing.small
                        text: qsTr("YOUR BITCOIN KEY")
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }
                    LogosText {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("Share this with whoever sets up a Bitcoin multisig with you (Accounts → "
                                 + "Bitcoin multisig). It's the public half of your authorization key, "
                                 + "compressed — the key your in-app approvals sign with.")
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        TextEdit {
                            id: btcKeyField
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            readOnly: true
                            selectByMouse: true
                            wrapMode: TextEdit.WrapAnywhere
                            text: String((settings.identity && settings.identity.btcPubKey) || "").replace(/^0x/i, "")
                            color: Theme.palette.textSecondary
                            selectionColor: Theme.palette.primary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }
                        LogosButton {
                            objectName: "copyBtcKey"
                            text: qsTr("Copy")
                            enabled: btcKeyField.text.length > 0
                            onClicked: { btcKeyField.selectAll(); btcKeyField.copy(); btcKeyField.deselect(); }
                        }
                    }

                    LogosText {
                        Layout.fillWidth: true
                        Layout.topMargin: 2
                        wrapMode: Text.WordWrap
                        text: qsTr("Your keys stay in the module's keystore — the client never hands them out. "
                                 + "Backup, import, and Keycard are the platform's to provide (basecamp).")
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }
                }
            }

            // ── infrastructure (invariant 8) ──────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: infraCol.implicitHeight + 2 * Theme.spacing.medium
                radius: Theme.spacing.radiusMedium
                color: Theme.palette.surface
                border.width: 1
                border.color: Theme.palette.borderSubtle

                ColumnLayout {
                    id: infraCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.spacing.medium
                    spacing: Theme.spacing.small

                    LogosText {
                        text: qsTr("INFRASTRUCTURE")
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }

                    LogosText {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("Store nodes and RPC are untrusted infrastructure you choose (invariant 8). "
                                 + "Point them at your own node.")
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }

                    // ── Ethereum chains ──
                    // Under the platform (exo-d4d) the person's chains and endpoints are set once
                    // for the device, in the Ethereum RPC app; muster reads them and never writes.
                    // muster's own RPC URL is for a host without that (the runner, a test chain).
                    ColumnLayout {
                        visible: !!(settings.s && settings.s.evmPlatform)
                        Layout.fillWidth: true
                        spacing: Theme.spacing.tiny
                        LogosText {
                            text: qsTr("Ethereum chains  ·  from your device's chain settings (eth_rpc_module)")
                            color: Theme.palette.textSecondary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }
                        RowLayout {
                            spacing: Theme.spacing.small
                            LogosButton {
                                objectName: "chainSettings"
                                text: qsTr("Open chain settings")
                                variant: LogosButton.Variant.Secondary
                                onClicked: {
                                    if (typeof logos === "undefined" || typeof logos.request !== "function") {
                                        settings.chainNote = qsTr("Open the Ethereum RPC app from Basecamp.");
                                        return;
                                    }
                                    settings.chainNote = "";
                                    logos.request("evm.rpc.configure", {}, function (res) {
                                        if (res && res.error === "unavailable")
                                            settings.chainNote = qsTr("No chain settings app answered: install Ethereum RPC from Basecamp.");
                                    });
                                }
                            }
                            LogosText {
                                visible: settings.chainNote.length > 0
                                text: settings.chainNote
                                color: Theme.palette.warning
                                font.pixelSize: Theme.typography.badgeText
                            }
                        }
                    }
                    // ── RPC endpoint (muster's own, when not on the platform) ──
                    RowLayout {
                        visible: !(settings.s && settings.s.evmPlatform)
                        spacing: Theme.spacing.small
                        LogosText {
                            objectName: "settingsRpcNow"
                            text: qsTr("RPC endpoint  ·  now: %1")
                                  .arg(String((settings.s && (settings.showRpc ? settings.s.rpc
                                                                               : settings.s.rpcMasked)) || "(unset)"))
                            color: Theme.palette.textSecondary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }
                        LogosButton {
                            objectName: "settingsRpcShow"
                            visible: !!(settings.s && settings.s.rpc && settings.s.rpc !== settings.s.rpcMasked)
                            text: settings.showRpc ? qsTr("Hide") : qsTr("Show")
                            variant: LogosButton.Variant.Tertiary
                            onClicked: settings.showRpc = !settings.showRpc
                        }
                    }
                    RowLayout {
                        visible: !(settings.s && settings.s.evmPlatform)
                        Layout.fillWidth: true
                        Layout.maximumWidth: 460       // keep the input a tidy width, not full-bleed
                        Layout.alignment: Qt.AlignLeft
                        spacing: Theme.spacing.small
                        LogosTextField {
                            id: rpcField
                            objectName: "settingsRpc"
                            Layout.fillWidth: true
                            placeholderText: qsTr("new RPC URL, e.g. http://127.0.0.1:8545")
                            font.family: Theme.typography.mono
                        }
                        LogosButton {
                            objectName: "settingsRpcSave"
                            text: qsTr("Save")
                            enabled: rpcField.text.length > 0
                            onClicked: {
                                if (settings.backend) settings.backend.setSetting("rpc", rpcField.text);
                                rpcField.text = "";
                            }
                        }
                    }

                    // ── the user's Bitcoin node (exo-a50.2.6) ──
                    RowLayout {
                        Layout.topMargin: Theme.spacing.small
                        spacing: Theme.spacing.small
                        LogosText {
                            objectName: "settingsBtcRpcNow"
                            text: qsTr("Bitcoin node  ·  now: %1")
                                  .arg(String((settings.s && (settings.showBtcRpc ? settings.s.btcRpc
                                                                                  : settings.s.btcRpcMasked))
                                              || "(none — a Bitcoin payment needs one)"))
                            color: Theme.palette.textSecondary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }
                        LogosButton {
                            objectName: "settingsBtcRpcShow"
                            visible: !!(settings.s && settings.s.btcRpc && settings.s.btcRpc !== settings.s.btcRpcMasked)
                            text: settings.showBtcRpc ? qsTr("Hide") : qsTr("Show")
                            variant: LogosButton.Variant.Tertiary
                            onClicked: settings.showBtcRpc = !settings.showBtcRpc
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.maximumWidth: 460
                        Layout.alignment: Qt.AlignLeft
                        spacing: Theme.spacing.small
                        LogosTextField {
                            id: btcRpcField
                            objectName: "settingsBtcRpc"
                            Layout.fillWidth: true
                            // the credentials travel as Basic auth, and show above only behind Show
                            placeholderText: qsTr("your node, e.g. http://user:pass@127.0.0.1:8332")
                            font.family: Theme.typography.mono
                        }
                        LogosButton {
                            objectName: "settingsBtcRpcSave"
                            text: qsTr("Save")
                            enabled: btcRpcField.text.length > 0
                            onClicked: {
                                if (settings.backend) settings.backend.setSetting("btc-rpc", btcRpcField.text);
                                btcRpcField.text = "";
                            }
                        }
                    }

                    // ── the user's LEZ sequencer (exo-3c9) ──
                    RowLayout {
                        Layout.topMargin: Theme.spacing.small
                        spacing: Theme.spacing.small
                        LogosText {
                            objectName: "settingsLezRpcNow"
                            text: qsTr("LEZ sequencer  ·  now: %1  (%2)")
                                  .arg(String((settings.s && settings.s.lez && (settings.showLezRpc ? settings.s.lez.rpc
                                                                                                    : settings.s.lez.rpcMasked))
                                              || "https://testnet.lez.logos.co"))
                                  .arg(String((settings.s && settings.s.lez && settings.s.lez.chain) || "lez:testnet"))
                            color: Theme.palette.textSecondary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }
                        LogosButton {
                            objectName: "settingsLezRpcShow"
                            visible: !!(settings.s && settings.s.lez && settings.s.lez.rpc
                                        && settings.s.lez.rpc !== settings.s.lez.rpcMasked)
                            text: settings.showLezRpc ? qsTr("Hide") : qsTr("Show")
                            variant: LogosButton.Variant.Tertiary
                            onClicked: settings.showLezRpc = !settings.showLezRpc
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.maximumWidth: 460
                        Layout.alignment: Qt.AlignLeft
                        spacing: Theme.spacing.small
                        LogosTextField {
                            id: lezRpcField
                            objectName: "settingsLezRpc"
                            Layout.fillWidth: true
                            placeholderText: qsTr("your sequencer, e.g. http://127.0.0.1:3040")
                            font.family: Theme.typography.mono
                        }
                        LogosButton {
                            objectName: "settingsLezRpcSave"
                            text: qsTr("Save")
                            enabled: lezRpcField.text.length > 0
                            onClicked: {
                                if (settings.backend) settings.backend.setSetting("lez-rpc", lezRpcField.text);
                                lezRpcField.text = "";
                            }
                        }
                    }

                    // ── delivery config ──
                    LogosText {
                        Layout.topMargin: Theme.spacing.small
                        text: qsTr("Delivery node config  ·  now: %1")
                              .arg(String((settings.s && settings.s.delivery) || "{}"))
                        color: Theme.palette.textSecondary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.maximumWidth: 460       // keep the input a tidy width, not full-bleed
                        Layout.alignment: Qt.AlignLeft
                        spacing: Theme.spacing.small
                        LogosTextField {
                            id: deliveryField
                            objectName: "settingsDelivery"
                            Layout.fillWidth: true
                            placeholderText: qsTr("full createNode JSON, or a fleet name: 'logos.dev' or 'logos.test'")
                            font.family: Theme.typography.mono
                        }
                        LogosButton {
                            objectName: "settingsDeliverySave"
                            text: qsTr("Save")
                            enabled: deliveryField.text.length > 0
                            onClicked: {
                                if (settings.backend) settings.backend.setSetting("delivery", deliveryField.text);
                                deliveryField.text = "";
                            }
                        }
                    }
                    // one-click presets, no JSON to paste. logos.dev is the default; since
                    // Testnet v0.3 a node on logos.test sends nothing until it has an active
                    // RLN membership (exo-eb6.3), so the button says so.
                    RowLayout {
                        spacing: Theme.spacing.small
                        LogosButton {
                            objectName: "settingsDeliveryFleet"
                            text: qsTr("Use the logos.dev fleet")
                            variant: LogosButton.Variant.Secondary
                            onClicked: if (settings.backend) settings.backend.setSetting("delivery", "logos.dev")
                        }
                        LogosButton {
                            objectName: "settingsDeliveryFleetTest"
                            text: qsTr("Use logos.test (needs an RLN membership)")
                            variant: LogosButton.Variant.Secondary
                            onClicked: if (settings.backend) settings.backend.setSetting("delivery", "logos.test")
                        }
                    }

                    // ── the mixnet for sends (exo-dcc.4) ──
                    // Delivery's sender anonymity: each send goes over three mix hops to an
                    // exit that publishes it. It carries sends only, and the text says so.
                    LogosText {
                        Layout.topMargin: Theme.spacing.small
                        text: qsTr("MIXNET FOR SENDS")
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }
                    LogosText {
                        objectName: "settingsMixNow"
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        // the level the next node is asked for differs from the setting only
                        // when the delivery config names its own (or turns mix off)
                        readonly property string level: String((settings.s && settings.s.mix) || "off")
                        readonly property string asked: String((settings.s && settings.s.mixAsked) || "")
                        text: qsTr("now: %1").arg(level)
                              + ((asked.length > 0 && asked.toLowerCase() !== (level === "off" ? "none" : level))
                                 ? qsTr("  ·  the delivery config asks for %1 itself").arg(asked) : "")
                        color: Theme.palette.textSecondary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                    }
                    RowLayout {
                        spacing: Theme.spacing.small
                        LogosButton {
                            objectName: "settingsMixOff"
                            text: qsTr("Off")
                            variant: LogosButton.Variant.Secondary
                            onClicked: if (settings.backend) settings.backend.setSetting("mix", "off")
                        }
                        LogosButton {
                            objectName: "settingsMixPreferred"
                            text: qsTr("Preferred")
                            variant: LogosButton.Variant.Secondary
                            onClicked: if (settings.backend) settings.backend.setSetting("mix", "preferred")
                        }
                        LogosButton {
                            objectName: "settingsMixRequired"
                            text: qsTr("Required")
                            variant: LogosButton.Variant.Secondary
                            onClicked: if (settings.backend) settings.backend.setSetting("mix", "required")
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        visible: !!settings.mix.detail
                        spacing: Theme.spacing.small
                        Rectangle {
                            Layout.alignment: Qt.AlignTop
                            Layout.topMargin: 5
                            Layout.preferredWidth: 8
                            Layout.preferredHeight: 8
                            radius: 4
                            color: settings.mix.level === "ok" ? Theme.palette.success
                                 : settings.mix.level === "warn" ? Theme.palette.warning
                                 : settings.mix.level === "down" ? Theme.palette.error
                                 : Theme.palette.textTertiary
                        }
                        LogosText {
                            objectName: "settingsMixDetail"
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: String(settings.mix.detail || "")
                            color: Theme.palette.textSecondary
                            font.pixelSize: Theme.typography.secondaryText
                        }
                    }
                    LogosText {
                        Layout.fillWidth: true
                        visible: !!settings.mix.remedy
                        wrapMode: Text.WordWrap
                        text: String(settings.mix.remedy || "")
                        color: Theme.palette.warning
                        font.pixelSize: Theme.typography.badgeText
                    }
                    LogosText {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("Preferred and Required send each room message through the Logos mixnet: three mix hops, "
                                 + "then an exit that publishes it, so the relay and store nodes do not learn which node sent it. "
                                 + "Preferred takes the plain path when the mixnet cannot carry a send; Required never does, so "
                                 + "that send fails. The mixnet carries sends only: reading a room still asks a store node for "
                                 + "the room's topic from this node's own address. On logos.dev most mix nodes are the fleet "
                                 + "operator's, who also runs the store nodes. Applies the next time Muster starts.")
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }

                    // ── RLN membership (exo-eb6.3) ──
                    // This node's own membership: on logos.test a node sends nothing without
                    // one. The RLN modules register by themselves once the node's payer is
                    // funded, so the one thing shown to act on is that payer, whole, to copy.
                    LogosText {
                        Layout.topMargin: Theme.spacing.small
                        text: qsTr("RLN MEMBERSHIP")
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        Rectangle {
                            Layout.alignment: Qt.AlignTop
                            Layout.topMargin: 5
                            Layout.preferredWidth: 8
                            Layout.preferredHeight: 8
                            radius: 4
                            color: settings.rln.level === "ok" ? Theme.palette.success
                                 : settings.rln.level === "warn" ? Theme.palette.warning
                                 : settings.rln.level === "down" ? Theme.palette.error
                                 : Theme.palette.textTertiary
                        }
                        LogosText {
                            objectName: "settingsRlnDetail"
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: settings.rln.detail ? String(settings.rln.detail) : qsTr("checking…")
                            color: Theme.palette.textSecondary
                            font.pixelSize: Theme.typography.secondaryText
                        }
                    }
                    LogosText {
                        Layout.fillWidth: true
                        visible: !!settings.rln.remedy
                        wrapMode: Text.WordWrap
                        text: String(settings.rln.remedy || "")
                        color: Theme.palette.warning
                        font.pixelSize: Theme.typography.badgeText
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        visible: rlnPayerField.text.length > 0
                        spacing: Theme.spacing.small
                        TextEdit {
                            id: rlnPayerField
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            readOnly: true
                            selectByMouse: true
                            wrapMode: TextEdit.WrapAnywhere
                            text: String(settings.rln.payer || "")
                            color: Theme.palette.textSecondary
                            selectionColor: Theme.palette.primary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }
                        LogosButton {
                            objectName: "copyRlnPayer"
                            text: qsTr("Copy payer")
                            onClicked: { rlnPayerField.selectAll(); rlnPayerField.copy(); rlnPayerField.deselect(); }
                        }
                    }
                    LogosText {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("On logos.test every message carries an RLN proof, so a node sends nothing until "
                                 + "it has an active membership, funded on the registry's own zone. logos.dev runs no RLN.")
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }

                    // ── EVM keystore (exo-149.1 K1) ──
                    // keystore_module holds the EVM keys; muster reads its accounts and will
                    // ask it for signatures a person approves in the signer. This row says
                    // whether it is there and whether it sees muster's requests as muster's.
                    LogosText {
                        Layout.topMargin: Theme.spacing.small
                        text: qsTr("EVM KEYSTORE")
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        Rectangle {
                            Layout.alignment: Qt.AlignTop
                            Layout.topMargin: 5
                            Layout.preferredWidth: 8
                            Layout.preferredHeight: 8
                            radius: 4
                            color: settings.keystore.level === "ok" ? Theme.palette.success
                                 : settings.keystore.level === "warn" ? Theme.palette.warning
                                 : settings.keystore.level === "down" ? Theme.palette.error
                                 : Theme.palette.textTertiary
                        }
                        LogosText {
                            objectName: "settingsKeystoreDetail"
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: settings.keystore.detail ? String(settings.keystore.detail) : qsTr("checking…")
                            color: Theme.palette.textSecondary
                            font.pixelSize: Theme.typography.secondaryText
                        }
                    }
                    LogosText {
                        Layout.fillWidth: true
                        visible: !!settings.keystore.remedy
                        wrapMode: Text.WordWrap
                        text: String(settings.keystore.remedy || "")
                        color: Theme.palette.warning
                        font.pixelSize: Theme.typography.badgeText
                    }
                    // exo-d4d.2: muster never makes keys. Creating, importing and backing up an
                    // account is the platform keystore app's (evm_keystore_ui), reached by
                    // the evm.accounts.manage intent; Settings re-reads the row when it returns.
                    RowLayout {
                        visible: (settings.keystore.identity || {}).kind === "module"
                        spacing: Theme.spacing.small
                        LogosButton {
                            objectName: "keystoreManage"
                            text: (settings.keystore.accounts || []).length === 0
                                  ? qsTr("Create or import an account") : qsTr("Manage accounts")
                            variant: LogosButton.Variant.Secondary
                            onClicked: {
                                if (typeof logos === "undefined" || typeof logos.request !== "function") {
                                    settings.manageNote = qsTr("Open the Logos keystore app from Basecamp.");
                                    return;
                                }
                                settings.manageNote = "";
                                logos.request("evm.accounts.manage", {}, function (res) {
                                    if (res && res.error === "unavailable")
                                        settings.manageNote = qsTr("No keystore app answered: install or open it from Basecamp.");
                                    if (settings.backend) settings.backend.loadKeystoreStatus();
                                });
                            }
                        }
                        LogosText {
                            visible: settings.manageNote.length > 0
                            text: settings.manageNote
                            color: Theme.palette.warning
                            font.pixelSize: Theme.typography.badgeText
                        }
                    }
                    Repeater {
                        model: settings.keystore.accounts || []
                        // one account per block: its address, then (on its own line) the button.
                        // In one RowLayout beside a fill-width elided address, the button never
                        // drew inside Basecamp 0.3.1 (exo-d4d.2, seen on display).
                        delegate: ColumnLayout {
                            id: acctRow
                            required property var modelData
                            readonly property bool chosen: String(settings.keystore.selected || "")
                                                           === String(modelData.address).toLowerCase()
                            Layout.fillWidth: true
                            spacing: 2
                            LogosText {
                                Layout.fillWidth: true
                                elide: Text.ElideMiddle
                                text: (acctRow.chosen ? "● " : "")
                                      + (acctRow.modelData.label ? acctRow.modelData.label + "  " : "")
                                      + (acctRow.modelData.wallet ? "(" + acctRow.modelData.wallet + ")  " : "")
                                      + acctRow.modelData.address
                                color: acctRow.chosen ? Theme.palette.textPrimary : Theme.palette.textSecondary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                            }
                            LogosButton {
                                objectName: "keystoreUse"
                                visible: !acctRow.chosen && settings.keystore.on === true
                                text: qsTr("Use for approvals")
                                variant: LogosButton.Variant.Secondary
                                onClicked: if (settings.backend) settings.backend.keystoreSelect(acctRow.modelData.address)
                            }
                        }
                    }
                    // the selected account's binding: what lets the room tell its approvals are yours
                    LogosText {
                        objectName: "settingsKeystoreBinding"
                        Layout.fillWidth: true
                        visible: !!settings.keystore.selected
                        wrapMode: Text.WordWrap
                        text: {
                            const b = String(settings.keystore.binding || "none")
                            if (b === "valid") return qsTr("Approvals go through the selected account, linked to your Muster identity.")
                            if (b === "expiring") return qsTr("The account's link to your identity expires within a day: select it again to renew.")
                            if (b === "expired" || b === "invalid") return qsTr("The account's link to your identity is no longer valid: ask again.")
                            // not linked yet: say where the request stands, and who must answer it
                            if (settings.bindingWaiting)
                                return qsTr("Approve linking this account to your identity in the Logos Signer (%1), a separate app. "
                                            + "Not installed? Install it, then open the request.").arg(settings.signerPackage)
                            var st = settings.bindingRequest ? String(settings.bindingRequest.state || "") : "";
                            return st.length > 0
                                ? qsTr("The link request ended without an approval (%1). Install or open the Logos Signer (%2), then ask again.").arg(st).arg(settings.signerPackage)
                                : qsTr("The account is not linked to your identity yet. Ask for the link, then approve it in the Logos Signer (%1).").arg(settings.signerPackage)
                        }
                        color: settings.keystore.binding === "valid" ? Theme.palette.textTertiary : Theme.palette.warning
                        font.pixelSize: Theme.typography.badgeText
                    }
                    // what to do about it: open the request, ask again, install the signer (exo-dcc.27)
                    Flow {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        visible: !!settings.keystore.selected && settings.keystore.binding !== "valid"
                        LogosButton {
                            objectName: "keystoreOpenSigner"
                            visible: settings.bindingWaiting
                            text: qsTr("Open the request in the Signer")
                            onClicked: settings.openSignerRequested(String(settings.bindingRequest.handle || ""))
                        }
                        LogosButton {
                            objectName: "keystoreAskAgain"
                            visible: !settings.bindingWaiting
                            text: qsTr("Ask again")
                            onClicked: if (settings.backend) settings.backend.keystoreSelect(String(settings.keystore.selected))
                        }
                        LogosButton {
                            objectName: "keystoreInstallSigner"
                            text: qsTr("Install the Logos Signer")
                            variant: LogosButton.Variant.Secondary
                            onClicked: settings.signerInstallRequested()
                        }
                    }
                    LogosText {
                        Layout.fillWidth: true
                        visible: !!settings.signerInstall.state && settings.keystore.binding !== "valid"
                        wrapMode: Text.WordWrap
                        text: {
                            var st = String(settings.signerInstall.state || "");
                            return st === "open" ? qsTr("Package Manager is open on the Logos Signer: confirm the install there, then come back.")
                                 : st === "asking" ? qsTr("Asking Basecamp to install the Logos Signer…")
                                 : st === "unavailable" ? qsTr("No Package Manager answered: install %1 from Basecamp's Package Manager.").arg(settings.signerPackage)
                                 : qsTr("Installing the Logos Signer did not start (%1).").arg(String(settings.signerInstall.error || st));
                        }
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }

                    LogosText {
                        Layout.fillWidth: true
                        Layout.topMargin: 2
                        wrapMode: Text.WordWrap
                        text: qsTr("RPC applies to the wallet/Safe path on next use; delivery config applies the "
                                 + "next time Muster starts (one node per run). Saved beside your keystore (settings.json), so they survive a restart; inside basecamp the platform's own settings are the eventual home.")
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }
                }
            }

            // ── about & legal (public-release disclaimer) ─────────────────────
            // Placeholder wording — refine with legal. Muster ships as an
            // experimental, testnet-only demonstration tool; this states that plainly.
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: aboutCol.implicitHeight + 2 * Theme.spacing.medium
                radius: Theme.spacing.radiusMedium
                color: Theme.palette.surface
                border.width: 1
                border.color: Theme.palette.borderSubtle

                ColumnLayout {
                    id: aboutCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.spacing.medium
                    spacing: Theme.spacing.tiny

                    LogosText {
                        text: qsTr("ABOUT & LEGAL")
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }
                    LogosText {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("Muster is experimental, pre-release software for demonstration and "
                                 + "education only. It is unaudited and provided “as is”, without "
                                 + "warranty of any kind, and may contain bugs that cause loss of data or "
                                 + "funds. Do NOT use it with real assets or on mainnet — connect only "
                                 + "to test networks. Nothing here is financial, investment, or legal "
                                 + "advice. By using this software you accept all risk.")
                        color: Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.secondaryText
                    }
                }
            }
        }
    }
}
