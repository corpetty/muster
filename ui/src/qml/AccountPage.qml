import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The Account surface (exo-720.6, moved verbatim out of Main.qml): the local test Safe a
// member may disclose into a room, its owners, a direct propose → approve → submit, and the
// wallet's balances. `root` is Main, as before the move. U7 (exo-720.11) turns it into the
// Wallet and puts the Safe dashboard behind a dev setting (decision §6.3).
Item {
    required property var root   // Main.qml's root (its mainItem)

    ColumnLayout {
        id: page
        visible: root.view === "dashboard"
        // under the Wallet's header (Main.qml), aligned with it (exo-720.11)
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.leftMargin: Theme.spacing.xxlarge
        anchors.topMargin: Theme.spacing.xlarge
        anchors.bottomMargin: Theme.spacing.xlarge
        spacing: Theme.spacing.large
        width: Math.min(parent.width - 2 * Theme.spacing.xxlarge, 640)

        // Like Muster? (exo-168): said once, after a wallet of the person's own is connected
        InlineNotice {
            objectName: "supportPrompt"
            visible: root.supportPromptShown
            Layout.fillWidth: true
            tone: "info"
            title: qsTr("Like Muster?")
            text: qsTr("It's a personal project on the Logos stack. A tip from your wallet keeps it going: "
                       + "infrastructure, development time, audits. Testnet coins help too.")
            ActionButton {
                objectName: "supportPromptOpen"
                compact: true
                text: qsTr("Tell me more")
                iconSource: MusterStyle.icon("heart")
                onClicked: root.openSupport()
            }
            ActionButton {
                objectName: "supportPromptDismiss"
                compact: true
                quiet: true
                text: qsTr("Not now")
                onClicked: root.dismissSupportPrompt()
            }
        }

        // the wallets this instance was given, first (exo-f37)
        WalletList {
            objectName: "walletList"
            Layout.fillWidth: true
            summary: root.walletSummary
            loading: root.balancesLoading
            onConnectRequested: function (action, pkg) { root.walletConnect(action, pkg); }
        }

        ActionButton {
            objectName: "walletRefresh"
            Layout.alignment: Qt.AlignLeft
            Layout.topMargin: Theme.spacing.small
            quiet: true
            text: root.balancesLoading ? qsTr("Reading…") : qsTr("Refresh")
            enabled: !root.balancesLoading
            onClicked: root.refreshBalances()
        }

        // the local test Safe, a development surface: only where its chain answers
        LogosText {
            textFormat: Text.PlainText
            visible: !root.account || root.account.available !== false
            text: qsTr("The local test Safe — inspect it, act on it directly, and settle on-chain. "
                       + "To coordinate with people, open a Room.")
            color: Theme.palette.textTertiary
            font.pixelSize: Theme.typography.secondaryText
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            Layout.topMargin: Theme.spacing.large
        }

        // ── the local test Safe (a suggestion) ─────────────────────────────────
        // Shown from describe(): the anvil fixture a member MAY disclose into a room.
        // It is not a room's account — accounts live in the room, disclosed by members
        // (exo-a50.1.3). A null account renders as "not loaded", never fabricated. Hidden
        // where no chain 31337 is read (a fresh Basecamp install, exo-d4d.6).
        Rectangle {
            visible: !root.account || root.account.available !== false
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
                    textFormat: Text.PlainText
                    text: qsTr("LOCAL TEST SAFE · disclose it into a room to use it")
                    color: Theme.palette.textTertiary
                    font.family: MusterStyle.mono
                    font.pixelSize: MusterStyle.caption
                    font.weight: Theme.typography.weightMedium
                }

                LogosText {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    wrapMode: Text.WrapAnywhere
                    text: root.account
                        ? qsTr("Safe %1").arg(String(root.account.safe))
                        : qsTr("account not loaded")
                    color: Theme.palette.text
                    font.family: MusterStyle.mono
                    font.pixelSize: Theme.typography.secondaryText
                }

                LogosText {
                    textFormat: Text.PlainText
                    visible: !!root.account
                    text: root.account
                        ? qsTr("%1 of %2 owners · chain %3 · %4")
                            .arg(Number(root.account.threshold))
                            .arg(root.account.owners ? root.account.owners.length : 0)
                            .arg(Number(root.account.chainId))
                            .arg(String(root.account.environment))
                        : ""
                    color: Theme.palette.textSecondary
                    font.family: MusterStyle.mono
                    font.pixelSize: MusterStyle.caption
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
                        textFormat: Text.PlainText
                        id: ownersToggle
                        text: root.ownersOpen
                            ? qsTr("Owners — tap to hide  −")
                            : qsTr("Owners — tap to see all %1  +")
                                .arg(root.account && root.account.owners ? root.account.owners.length : 0)
                        color: Theme.palette.textSecondary
                        font.family: MusterStyle.mono
                        font.pixelSize: MusterStyle.caption
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
                        textFormat: Text.PlainText
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.leftMargin: Theme.spacing.small
                        wrapMode: Text.WrapAnywhere
                        text: "· " + String(modelData)
                        color: Theme.palette.textTertiary
                        font.family: MusterStyle.mono
                        font.pixelSize: MusterStyle.caption
                    }
                }
            }
        }

        // ── propose composer ──────────────────────────────────────────────────
        // The direct path drives the local test Safe; hidden where it cannot work (exo-d4d.6).
        Rectangle {
            visible: !root.account || root.account.available !== false
            Layout.fillWidth: true
            implicitHeight: composeCol.implicitHeight + 2 * Theme.spacing.medium
            radius: Theme.spacing.radiusMedium
            color: Theme.palette.surface
            border.width: 1
            border.color: Theme.palette.borderSubtle

            ColumnLayout {
                id: composeCol
                anchors.fill: parent
                anchors.margins: Theme.spacing.medium
                spacing: Theme.spacing.small

                LogosText {
                    textFormat: Text.PlainText
                    text: qsTr("Propose a transfer — directly")
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.primaryText
                    font.weight: Theme.typography.weightMedium
                }

                LogosText {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: qsTr("The direct path: you drive the whole lifecycle here — propose, "
                             + "collect signatures, settle on-chain. To decide it with people in "
                             + "a conversation instead, open a Room.")
                    color: Theme.palette.textTertiary
                    font.pixelSize: MusterStyle.caption
                }

                LogosTextField {
                    id: toField
                    objectName: "proposeTo"
                    Layout.fillWidth: true
                    placeholderText: qsTr("to (0x…)")
                    font.family: MusterStyle.mono
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosTextField {
                        id: valueField
                        objectName: "proposeValue"
                        Layout.fillWidth: true
                        placeholderText: qsTr("value")
                        font.family: MusterStyle.mono
                        validator: IntValidator { bottom: 0 }
                    }

                    LogosTextField {
                        id: nonceField
                        objectName: "proposeNonce"
                        Layout.preferredWidth: 120
                        placeholderText: qsTr("nonce")
                        font.family: MusterStyle.mono
                        validator: IntValidator { bottom: 0 }
                    }
                }

                ActionButton {
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
            border.color: Theme.palette.borderSubtle

            ColumnLayout {
                id: intentCol
                anchors.fill: parent
                anchors.margins: Theme.spacing.medium
                spacing: Theme.spacing.small

                // The effect, in plain terms: amount leads, destination follows.
                LogosText {
                    textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
                    text: qsTr("%1 · nonce %2")
                        .arg(root.intentId)
                        .arg(root.effect && root.effect.nonce !== undefined ? String(root.effect.nonce) : "0")
                    color: Theme.palette.textTertiary
                    font.family: MusterStyle.mono
                    font.pixelSize: MusterStyle.caption
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
                                color: step.lit ? Theme.palette.success : Theme.palette.borderSubtle
                            }

                            LogosText {
                                textFormat: Text.PlainText
                                text: step.modelData.t
                                color: step.lit ? Theme.palette.textSecondary : Theme.palette.textTertiary
                                font.family: MusterStyle.mono
                                font.pixelSize: MusterStyle.caption
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
                            textFormat: Text.PlainText
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
                                    textFormat: Text.PlainText
                                    Layout.preferredWidth: 72
                                    text: modelData.k
                                    color: Theme.palette.textTertiary
                                    font.family: MusterStyle.mono
                                    font.pixelSize: MusterStyle.caption
                                }

                                LogosText {
                                    textFormat: Text.PlainText
                                    Layout.fillWidth: true
                                    wrapMode: Text.WrapAnywhere
                                    text: modelData.v
                                    color: Theme.palette.textSecondary
                                    font.family: MusterStyle.mono
                                    font.pixelSize: MusterStyle.caption
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
                        font.family: MusterStyle.mono
                    }

                    ActionButton {
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
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("Each owner signs on their own device — the client never holds their keys. "
                                 + "%1 of %2 owners must sign; a signature counts only if it recovers to an owner.")
                            .arg(root.account ? Number(root.account.threshold) : 2)
                            .arg(root.account && root.account.owners ? root.account.owners.length : 3)
                        color: Theme.palette.textTertiary
                        font.pixelSize: MusterStyle.caption
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
                        textFormat: Text.PlainText
                        objectName: "executableNotice"
                        Layout.fillWidth: true
                        visible: root.isExecutable
                        wrapMode: Text.WordWrap
                        text: qsTr("✓ threshold met — the owner signatures are collected. Submit assembles the Safe execTransaction and sends it through your RPC.")
                        color: Theme.palette.success
                        font.pixelSize: MusterStyle.caption
                        font.weight: Theme.typography.weightMedium
                    }

                    ActionButton {
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
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        visible: root.isSubmitting
                        wrapMode: Text.WordWrap
                        text: qsTr("submitting… waiting for the receipt")
                        color: Theme.palette.textSecondary
                        font.pixelSize: MusterStyle.caption
                    }

                    LogosText {
                        textFormat: Text.PlainText
                        objectName: "finalNotice"
                        Layout.fillWidth: true
                        visible: root.isFinal
                        wrapMode: Text.WordWrap
                        text: qsTr("✓ executed on-chain — final. The transfer settled through the Safe; finality was read from the chain, not asserted by a service.")
                        color: Theme.palette.success
                        font.pixelSize: MusterStyle.caption
                        font.weight: Theme.typography.weightMedium
                    }

                    ActionButton {
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
                    textFormat: Text.PlainText
                    objectName: "errorText"
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: root.lastError
                    color: Theme.palette.error
                    font.pixelSize: MusterStyle.caption
                }

                // Recovery from any error — including a submit that never landed.
                ActionButton {
                    objectName: "errorResetButton"
                    visible: root.hasIntent
                    text: qsTr("New proposal")
                    onClicked: { if (root.backend) root.backend.reset(); }
                }
            }
        }

        // ── health footer (the loading-spike smoke test, kept) ────────────────
        // a development line: shown beside the local test Safe, never in a person's Wallet
        RowLayout {
            visible: !root.account || root.account.available !== false
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
                textFormat: Text.PlainText
                text: root.ready ? qsTr("module.health() → %1").arg(root.health)
                                 : qsTr("connecting to backend…")
                color: Theme.palette.textTertiary
                font.family: MusterStyle.mono
                font.pixelSize: MusterStyle.caption
            }
        }
    }
}
