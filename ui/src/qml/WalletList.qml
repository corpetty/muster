import QtQuick
import QtQuick.Layouts
import Logos.Theme
import Logos.Controls
import Logos.Icons

// The wallets this instance has been given (exo-f37): the module's wallet_summary, as cards
// — Ethereum only once an account was chosen for Muster, the Monero wallet open in Monero
// Wallet, the LEZ wallet — each with its address and balances, and under them how to
// connect what is not. Nothing here is a default account: what the person never set up is
// a line saying how, never a balance. A balance not read yet reads "reading…", never 0.
ColumnLayout {
    id: list

    property var summary: ({})          // wallet_summary, parsed
    property bool loading: false
    signal connectRequested(string action, string pkg)

    readonly property var wallets: (summary && Array.isArray(summary.wallets)) ? summary.wallets : []
    readonly property var connects: (summary && Array.isArray(summary.connect)) ? summary.connect : []
    readonly property var checking: (summary && Array.isArray(summary.checking)) ? summary.checking : []

    // a chain as people say it
    function chainName(c) {
        c = String(c || "");
        var ids = { "evm:1": "Ethereum", "evm:11155111": "Sepolia", "evm:17000": "Holesky",
                    "evm:560048": "Hoodi", "evm:31337": "local test chain",
                    "monero:mainnet": "mainnet", "monero:stagenet": "stagenet", "monero:testnet": "testnet",
                    "lez:testnet": "LEZ testnet", "mock:shielded": "demo" };
        if (ids[c] !== undefined) return ids[c];
        if (c.indexOf("evm:") === 0) return qsTr("chain %1").arg(c.slice(4));
        return c;
    }

    spacing: Theme.spacing.medium

    Repeater {
        model: list.wallets
        delegate: Surface {
            id: card
            required property var modelData
            objectName: "wallet_" + String(modelData.id || "")
            Layout.fillWidth: true
            implicitHeight: col.implicitHeight + 2 * Theme.spacing.large

            ColumnLayout {
                id: col
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.spacing.large
                spacing: Theme.spacing.small

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    LogosText {
                        textFormat: Text.PlainText
                        text: String(card.modelData.name || "")
                        color: Theme.palette.text
                        font.pixelSize: MusterStyle.subtitle
                        font.weight: Theme.typography.weightBold
                    }
                    StatusPill {
                        visible: !!card.modelData.dev
                        text: qsTr("development")
                        tone: "waiting"
                    }
                    StatusPill {
                        visible: String(card.modelData.network || "").length > 0
                        text: String(card.modelData.network || "")
                        tone: "info"
                    }
                    StatusPill {
                        visible: String(card.modelData.state || "") === "syncing" || String(card.modelData.state || "") === "opening"
                        text: String(card.modelData.state || "") === "syncing" ? qsTr("syncing") : qsTr("opening")
                        tone: "waiting"
                    }
                    Item { Layout.fillWidth: true }
                }
                LogosText {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: String(card.modelData.wallet || "").length > 0
                          ? qsTr("Wallet “%1”, through %2").arg(String(card.modelData.wallet)).arg(String(card.modelData.via || ""))
                          : qsTr("Through %1").arg(String(card.modelData.via || ""))
                    color: Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.caption
                }

                // the address, whole on hover and copyable
                RowLayout {
                    visible: String(card.modelData.account || "").length > 0
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    LogosText {
                        textFormat: Text.PlainText
                        objectName: "walletAddress_" + String(card.modelData.id || "")
                        Layout.fillWidth: true
                        elide: Text.ElideMiddle
                        text: String(card.modelData.account || "")
                        color: Theme.palette.text
                        font.family: MusterStyle.mono
                        font.pixelSize: MusterStyle.caption
                        HoverHandler { id: addrHover }
                        LogosToolTip { visible: addrHover.hovered; text: String(card.modelData.account || "") }
                    }
                    ActionButton {
                        id: copyAddr
                        property bool done: false
                        compact: true
                        quiet: true
                        text: copyAddr.done ? qsTr("Copied") : qsTr("Copy")
                        iconSource: LogosIcons.copy
                        onClicked: {
                            addrClip.text = String(card.modelData.account || "");
                            addrClip.selectAll(); addrClip.copy();
                            copyAddr.done = true; copyReset.restart();
                        }
                        Timer { id: copyReset; interval: 2000; onTriggered: copyAddr.done = false }
                    }
                }

                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.palette.borderSubtle }

                Repeater {
                    // through a Repeater a nested array is a Qt list, which Array.isArray rejects
                    model: (card.modelData.balances && card.modelData.balances.length > 0) ? card.modelData.balances : []
                    delegate: RowLayout {
                        id: row
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosText {
                            textFormat: Text.PlainText
                            text: String(row.modelData.asset || "")
                            color: Theme.palette.text
                            font.pixelSize: MusterStyle.body
                            font.weight: Theme.typography.weightMedium
                        }
                        LogosText {
                            textFormat: Text.PlainText
                            text: list.chainName(row.modelData.chain)
                            color: Theme.palette.textTertiary
                            font.pixelSize: MusterStyle.caption
                        }
                        Item { Layout.fillWidth: true }
                        // F-10, said plainly: checked by this client, or only reported to it
                        StatusPill {
                            objectName: "walletGrade"
                            visible: !row.modelData.error && !row.modelData.pending
                            text: row.modelData.grade === "verified-locally" ? qsTr("verified") : qsTr("reported")
                            tone: row.modelData.grade === "verified-locally" ? "settled" : "waiting"
                            HoverHandler { id: gradeHover }
                            LogosToolTip {
                                visible: gradeHover.hovered
                                text: row.modelData.grade === "verified-locally"
                                      ? qsTr("Your client checked this balance against the chain itself.")
                                      : qsTr("What your node or wallet reported. Your client has not checked it against the chain.")
                            }
                        }
                        ColumnLayout {
                            spacing: 0
                            LogosText {
                                textFormat: Text.PlainText
                                Layout.alignment: Qt.AlignRight
                                objectName: "walletBalance_" + String(card.modelData.id || "")
                                text: row.modelData.error ? qsTr("unavailable")
                                    : row.modelData.pending ? qsTr("reading…")
                                    : String(row.modelData.display || "")
                                color: row.modelData.error ? MusterStyle.warning
                                     : row.modelData.pending ? Theme.palette.textTertiary : Theme.palette.text
                                font.family: MusterStyle.mono
                                font.pixelSize: MusterStyle.body
                                HoverHandler { id: errHover }
                                LogosToolTip { visible: errHover.hovered && !!row.modelData.error; text: String(row.modelData.error || "") }
                            }
                            LogosText {
                                textFormat: Text.PlainText
                                Layout.alignment: Qt.AlignRight
                                visible: String(row.modelData.unlocked || "").length > 0
                                         && String(row.modelData.unlocked) !== String(row.modelData.display)
                                text: qsTr("%1 spendable now").arg(String(row.modelData.unlocked || ""))
                                color: Theme.palette.textTertiary
                                font.pixelSize: MusterStyle.caption
                            }
                        }
                    }
                }
                LogosText {
                    textFormat: Text.PlainText
                    visible: !card.modelData.balances || card.modelData.balances.length === 0
                    text: qsTr("No balances to read yet.")
                    color: Theme.palette.textTertiary
                    font.pixelSize: MusterStyle.caption
                }
            }
        }
    }

    // a wallet asked about but not answered yet
    Repeater {
        model: list.checking
        delegate: RowLayout {
            required property var modelData
            spacing: Theme.spacing.small
            Loading { running: true }
            LogosText {
                textFormat: Text.PlainText
                text: qsTr("Checking your %1 wallet…").arg(String(modelData))
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
            }
        }
    }

    // nothing connected (and nothing being checked): said once
    LogosText {
        textFormat: Text.PlainText
        objectName: "walletNone"
        visible: list.wallets.length === 0 && list.checking.length === 0 && !list.loading
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: qsTr("No wallets connected yet.")
        color: Theme.palette.textSecondary
        font.pixelSize: MusterStyle.body
    }

    // how to connect the rest
    ColumnLayout {
        visible: list.connects.length > 0
        Layout.fillWidth: true
        Layout.topMargin: Theme.spacing.small
        spacing: Theme.spacing.small
        SectionHeader { text: qsTr("Connect a wallet") }
        Repeater {
            model: list.connects
            delegate: RowLayout {
                id: hint
                required property var modelData
                objectName: "walletConnect_" + String(modelData.id || "")
                Layout.fillWidth: true
                spacing: Theme.spacing.medium
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    LogosText {
                        textFormat: Text.PlainText
                        text: String(hint.modelData.name || "")
                        color: Theme.palette.text
                        font.pixelSize: MusterStyle.body
                        font.weight: Theme.typography.weightMedium
                    }
                    LogosText {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: String(hint.modelData.how || "")
                        color: Theme.palette.textSecondary
                        font.pixelSize: MusterStyle.caption
                    }
                }
                ActionButton {
                    objectName: "walletConnectButton_" + String(hint.modelData.id || "")
                    compact: true
                    text: hint.modelData.action === "install" ? qsTr("Install")
                        : hint.modelData.action === "settings" ? qsTr("Open Settings")
                        : hint.modelData.action === "accounts" ? qsTr("Create or import")
                        : qsTr("Open Monero Wallet")
                    onClicked: list.connectRequested(String(hint.modelData.action || ""), String(hint.modelData.package || ""))
                }
            }
        }
    }

    TextEdit { textFormat: TextEdit.PlainText; id: addrClip; visible: false; width: 0; height: 0 }
}
