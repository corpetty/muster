import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Logos.Theme
import Logos.Controls
import Logos.Icons

// Like Muster? (exo-168): tip the project. The module's support_options, as one row per
// pinned address: what it pays for, who sees a payment, and how to pay it. A wallet the
// person connected sends from here (support_send, which names the option, never the
// address); a Monero or Bitcoin tip is its link and QR code, paid from any wallet, since
// Muster never spends Monero. Mainnets first, then the testnets that pay for live runs.
Popup {
    id: tip
    objectName: "supportDialog"

    property var backend: null
    readonly property var support: {
        try { return JSON.parse(tip.backend ? tip.backend.supportJson : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property var sent: {
        try { return JSON.parse(tip.backend ? tip.backend.supportSendJson : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property var options: (support && Array.isArray(support.options)) ? support.options : []
    readonly property var mainnets: options.filter(function (o) { return !o.testnet; })
    readonly property var testnets: options.filter(function (o) { return !!o.testnet; })
    property string sendingFor: ""   // the option a send is waiting on
    property string lastFor: ""      // the option the last answer is about
    property bool answered: false

    function openTip() {
        tip.answered = false;
        tip.open();
    }
    onOpened: if (tip.backend) tip.backend.loadSupport()
    onSentChanged: if (tip.sendingFor.length > 0) { tip.lastFor = tip.sendingFor; tip.sendingFor = ""; tip.answered = true; }

    anchors.centerIn: Overlay.overlay
    width: Math.min(560, (Overlay.overlay ? Overlay.overlay.width : 600) - 2 * Theme.spacing.large)
    height: Math.min(implicitHeight, (Overlay.overlay ? Overlay.overlay.height : 700) - 2 * Theme.spacing.large)
    modal: true
    focus: true
    padding: Theme.spacing.large
    background: Surface { level: 2 }

    // one pinned address: what it pays for, who sees it, and how to pay it
    component OptionRow: Surface {
        id: row
        required property var modelData
        readonly property var senders: (modelData.senders && modelData.senders.length > 0) ? modelData.senders : []
        readonly property string uri: String(modelData.uri || "")
        property bool qrShown: false
        objectName: "supportOption_" + String(modelData.id || "")
        Layout.fillWidth: true
        implicitHeight: rowCol.implicitHeight + 2 * Theme.spacing.medium

        ColumnLayout {
            id: rowCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacing.medium
            spacing: Theme.spacing.small

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                LogosText {
                    textFormat: Text.PlainText
                    text: String(row.modelData.name || "")
                    color: Theme.palette.text
                    font.pixelSize: MusterStyle.body
                    font.weight: Theme.typography.weightBold
                }
                StatusPill {
                    visible: !!row.modelData.testnet
                    text: qsTr("testnet")
                    tone: "info"
                }
                Item { Layout.fillWidth: true }
            }
            LogosText {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: String(row.modelData["for"] || "")
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
            }

            // the address, whole on hover and copyable
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                LogosText {
                    textFormat: Text.PlainText
                    objectName: "supportAddress_" + String(row.modelData.id || "")
                    Layout.fillWidth: true
                    elide: Text.ElideMiddle
                    text: String(row.modelData.address || "")
                    color: Theme.palette.text
                    font.family: MusterStyle.mono
                    font.pixelSize: MusterStyle.caption
                    HoverHandler { id: addrHover }
                    LogosToolTip { visible: addrHover.hovered; text: String(row.modelData.address || "") }
                }
                ActionButton {
                    id: copyAddr
                    property bool done: false
                    compact: true
                    quiet: true
                    text: copyAddr.done ? qsTr("Copied") : qsTr("Copy")
                    iconSource: LogosIcons.copy
                    onClicked: {
                        addrClip.text = String(row.modelData.address || "");
                        addrClip.selectAll(); addrClip.copy();
                        copyAddr.done = true; copyReset.restart();
                    }
                    Timer { id: copyReset; interval: 2000; onTriggered: copyAddr.done = false }
                }
                ActionButton {
                    visible: row.uri.length > 0
                    objectName: "supportQr_" + String(row.modelData.id || "")
                    compact: true
                    quiet: true
                    text: row.qrShown ? qsTr("Hide code") : qsTr("QR code")
                    iconSource: MusterStyle.icon("qr")
                    onClicked: row.qrShown = !row.qrShown
                }
            }
            QrCode {
                visible: row.qrShown && size > 0
                text: row.qrShown ? row.uri : ""
                Layout.preferredWidth: 180
                Layout.preferredHeight: 180
            }

            // who sees it, said before anything is sent
            LogosText {
                textFormat: Text.PlainText
                objectName: "supportDiscloses_" + String(row.modelData.id || "")
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("Who sees it: %1").arg(String(row.modelData.discloses ? row.modelData.discloses.note || "" : ""))
                color: Theme.palette.textTertiary
                font.pixelSize: MusterStyle.caption
            }

            // a connected wallet that holds something on this chain sends from here
            Repeater {
                model: row.senders
                delegate: ColumnLayout {
                    id: sender
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 2
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosText {
                            textFormat: Text.PlainText
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: qsTr("%1 from your %2 wallet%3 · %4")
                                  .arg(String(sender.modelData.asset || ""))
                                  .arg(String(sender.modelData.walletName || ""))
                                  .arg(sender.modelData.form === "shielded" ? qsTr(", shielded") : "")
                                  .arg(String(sender.modelData.display || ""))
                            color: Theme.palette.text
                            font.pixelSize: MusterStyle.caption
                        }
                        LogosTextField {
                            id: amount
                            objectName: "supportAmount_" + String(row.modelData.id || "")
                            Layout.preferredWidth: 120
                            placeholderText: qsTr("amount")
                            font.family: MusterStyle.mono
                            validator: RegularExpressionValidator { regularExpression: /^[0-9]*\.?[0-9]*$/ }
                        }
                        ActionButton {
                            objectName: "supportSend_" + String(row.modelData.id || "")
                            compact: true
                            text: tip.sendingFor === row.modelData.id ? qsTr("Sending…") : qsTr("Send")
                            iconSource: MusterStyle.icon("send")
                            enabled: tip.sendingFor.length === 0 && amount.text.length > 0 && Number(amount.text) > 0
                            onClicked: {
                                if (!tip.backend) return;
                                tip.answered = false;
                                tip.sendingFor = String(row.modelData.id || "");
                                tip.backend.sendSupport(tip.sendingFor, String(sender.modelData.account || ""),
                                                        String(sender.modelData.asset || ""), amount.text.trim());
                            }
                        }
                    }
                    // the LEZ: the rail follows the account sent from
                    LogosText {
                        textFormat: Text.PlainText
                        visible: sender.modelData.discloses
                                 && row.modelData.discloses
                                 && sender.modelData.discloses.note !== row.modelData.discloses.note
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: String(sender.modelData.discloses ? sender.modelData.discloses.note || "" : "")
                        color: Theme.palette.textTertiary
                        font.pixelSize: MusterStyle.caption
                    }
                }
            }

            // what came of a send from this row
            LogosText {
                textFormat: Text.PlainText
                objectName: "supportResult_" + String(row.modelData.id || "")
                visible: tip.answered && tip.lastFor === row.modelData.id
                Layout.fillWidth: true
                wrapMode: Text.WrapAnywhere
                text: tip.sent.error ? qsTr("Nothing was sent: %1").arg(String(tip.sent.error))
                    : qsTr("Sent. Thank you! Transaction %1").arg(String(tip.sent.txId || ""))
                color: tip.sent.error ? MusterStyle.refused : MusterStyle.settled
                font.pixelSize: MusterStyle.caption
            }

            TextEdit { textFormat: TextEdit.PlainText; id: addrClip; visible: false; width: 0; height: 0 }
        }
    }

    contentItem: Flickable {
        implicitHeight: body.implicitHeight
        contentHeight: body.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        ColumnLayout {
            id: body
            width: parent.width
            spacing: Theme.spacing.medium

            RowLayout {
                Layout.fillWidth: true
                LogosText {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: qsTr("Like Muster?")
                    color: Theme.palette.text
                    font.pixelSize: MusterStyle.subtitle
                    font.weight: Theme.typography.weightBold
                }
                IconAction {
                    label: qsTr("Close")
                    icon: LogosIcons.close
                    onClicked: tip.close()
                }
            }
            LogosText {
                textFormat: Text.PlainText
                objectName: "supportAbout"
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: String(tip.support.about || "")
                color: Theme.palette.text
                font.pixelSize: MusterStyle.body
            }
            LogosText {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("Send from a wallet you connected, or pay from any wallet with the link or QR code. "
                           + "These addresses are built into this copy of Muster; the project's site lists the same ones, "
                           + "so you can check them first.")
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
            }
            LogosText {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "corpetty.github.io/muster/support/"
                color: Theme.palette.textSecondary
                font.family: MusterStyle.mono
                font.pixelSize: MusterStyle.caption
            }

            EmptyState {
                objectName: "supportNone"
                visible: tip.options.length === 0
                Layout.fillWidth: true
                text: tip.support.error ? qsTr("The tip addresses could not be read: %1").arg(String(tip.support.error))
                                        : qsTr("This copy of Muster has no tip addresses yet.")
            }

            SectionHeader { visible: tip.mainnets.length > 0; text: qsTr("Tip") }
            Repeater { model: tip.mainnets; delegate: OptionRow {} }

            SectionHeader { visible: tip.testnets.length > 0; text: qsTr("Testnet coins, for the live test runs") }
            Repeater { model: tip.testnets; delegate: OptionRow {} }
        }
    }
}
