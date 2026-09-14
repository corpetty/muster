import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Send assets via Logos — the LEZ, Mode A (request → share → send). Two halves:
//   • the addresses you SHARE to be paid — a public id, or a shielded key node. Which
//     you share is your disclosure choice: a public id names you as payee, a key node
//     does not. Copy one and hand it to whoever is paying you.
//   • the send — paste their LEZ address, preview the rail + what it discloses (the
//     honesty before you commit), then send. The rail follows from (your source form,
//     what they shared): public/public, shield, deshield, private.
//
// PURE-RENDER: reads backend.walletAccountsJson / lezPreviewJson / lezSendJson; the
// only things that leave are previewLezSend / sendLez. Restricted to Theme keys and
// the Logos.Controls types the other views prove (LogosText, LogosButton,
// LogosTextField) + a readOnly TextEdit for the copyable share address (as Settings).
Item {
    id: lez

    property var backend
    property string fromId: ""

    readonly property var accounts: {
        try { return JSON.parse(backend ? backend.walletAccountsJson : "[]"); }
        catch (e) { return []; }
    }
    readonly property var lezAccounts: {
        var out = [];
        var a = lez.accounts || [];
        for (var i = 0; i < a.length; ++i)
            if (a[i] && String(a[i].chain) === "lez:testnet") out.push(a[i]);
        return out;
    }
    readonly property var preview: {
        try { return JSON.parse(backend ? backend.lezPreviewJson : "{}"); }
        catch (e) { return ({}); }
    }
    readonly property var sendResult: {
        try { return JSON.parse(backend ? backend.lezSendJson : "{}"); }
        catch (e) { return ({}); }
    }

    Component.onCompleted: if (lez.backend) lez.backend.loadWalletAccounts()

    function formLabel(f) { return f === "shielded" ? qsTr("shielded keys") : qsTr("public account"); }
    function shareHint(f) {
        return f === "shielded"
            ? qsTr("Share this to be paid privately — the amount and that it's you stay off the record.")
            : qsTr("Share this and the payment is public — anyone can see you were paid.");
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
                text: qsTr("Send λ on Logos")
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.subtitleText
                font.weight: Theme.typography.weightBold
            }
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("The Logos Execution Zone. Nobody has to approve a payment — you ask "
                         + "for the recipient's address and send. What they share decides how "
                         + "much is revealed.")
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.badgeText
            }

            // ── your addresses to be paid ──────────────────────────────────────
            LogosText {
                text: qsTr("YOUR ADDRESSES — SHARE ONE TO BE PAID")
                color: Theme.palette.textTertiary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
                font.weight: Theme.typography.weightMedium
            }
            Repeater {
                model: lez.lezAccounts
                delegate: Rectangle {
                    id: shareRow
                    required property var modelData
                    readonly property string form: String(shareRow.modelData.form || "")
                    readonly property string share: String(shareRow.modelData.share || shareRow.modelData.id || "")
                    Layout.fillWidth: true
                    implicitHeight: shareCol.implicitHeight + 2 * Theme.spacing.medium
                    radius: Theme.spacing.radiusMedium
                    color: Theme.palette.surface
                    border.width: 1
                    border.color: Theme.palette.borderSubtle

                    ColumnLayout {
                        id: shareCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.spacing.medium
                        spacing: Theme.spacing.tiny

                        LogosText {
                            text: lez.formLabel(shareRow.form)
                            color: Theme.palette.text
                            font.family: Theme.typography.publicSans
                            font.pixelSize: Theme.typography.secondaryText
                            font.weight: Theme.typography.weightMedium
                        }
                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: lez.shareHint(shareRow.form)
                            color: shareRow.form === "shielded" ? Theme.palette.success : Theme.palette.textTertiary
                            font.pixelSize: Theme.typography.badgeText
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            TextEdit {
                                id: shareField
                                Layout.fillWidth: true
                                readOnly: true
                                selectByMouse: true
                                wrapMode: TextEdit.WrapAnywhere
                                text: shareRow.share
                                color: Theme.palette.textSecondary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                            }
                            LogosButton {
                                text: qsTr("Copy")
                                variant: LogosButton.Variant.Secondary
                                onClicked: { shareField.selectAll(); shareField.copy(); }
                            }
                        }
                    }
                }
            }

            // ── send ───────────────────────────────────────────────────────────
            LogosText {
                text: qsTr("SEND")
                color: Theme.palette.textTertiary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
                font.weight: Theme.typography.weightMedium
            }
            // which of your accounts funds it (public or shielded — sets the rail)
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                LogosText {
                    text: qsTr("from")
                    color: Theme.palette.textTertiary
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.badgeText
                }
                Repeater {
                    model: lez.lezAccounts
                    delegate: LogosButton {
                        required property var modelData
                        text: lez.formLabel(String(modelData.form || ""))
                        variant: lez.fromId === String(modelData.id || "")
                                 ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                        onClicked: lez.fromId = String(modelData.id || "")
                    }
                }
            }
            LogosTextField {
                id: destField
                objectName: "lezDest"
                Layout.fillWidth: true
                placeholderText: qsTr("their LEZ address — a public id, or priv:npk:vpk")
                font.family: Theme.typography.mono
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                LogosTextField {
                    id: amtField
                    objectName: "lezAmount"
                    Layout.fillWidth: true
                    placeholderText: qsTr("amount (base units)")
                    font.family: Theme.typography.mono
                    validator: IntValidator { bottom: 0 }
                }
                LogosButton {
                    objectName: "lezPreviewButton"
                    text: qsTr("Preview")
                    enabled: lez.fromId.length > 0 && destField.text.length > 0 && amtField.text.length > 0
                    onClicked: if (lez.backend)
                        lez.backend.previewLezSend(lez.fromId, destField.text.trim(), amtField.text.trim());
                }
            }

            // the honesty, before you commit
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                visible: lez.preview && (lez.preview.rail !== undefined || lez.preview.error !== undefined)
                text: {
                    var p = lez.preview || ({});
                    if (p.error !== undefined) return qsTr("⚠ ") + String(p.error);
                    var d = p.discloses || ({});
                    var leaks = [];
                    if (d.amount) leaks.push(qsTr("amount"));
                    if (d.payer) leaks.push(qsTr("you (payer)"));
                    if (d.payee) leaks.push(qsTr("them (payee)"));
                    var what = leaks.length > 0 ? leaks.join(", ") : qsTr("nothing");
                    return qsTr("Rail: %1  ·  public record: %2  ·  %3")
                           .arg(String(p.rail || "?")).arg(what).arg(String(p.note || ""));
                }
                color: (lez.preview && lez.preview.error !== undefined) ? Theme.palette.warning : Theme.palette.textSecondary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
            }

            LogosButton {
                objectName: "lezSendButton"
                text: qsTr("Send")
                enabled: lez.fromId.length > 0 && destField.text.length > 0 && amtField.text.length > 0
                onClicked: if (lez.backend)
                    lez.backend.sendLez(lez.fromId, destField.text.trim(), amtField.text.trim());
            }

            // the outcome, reported honestly (a shielded send stays "settling" for
            // minutes — never a false "landed")
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WrapAnywhere
                visible: lez.sendResult && (lez.sendResult.txId !== undefined || lez.sendResult.error !== undefined)
                text: {
                    var r = lez.sendResult || ({});
                    if (r.error !== undefined) return qsTr("⚠ ") + String(r.error);
                    return qsTr("✓ sent on the %1 rail  ·  tx %2")
                           .arg(String(r.rail || "?")).arg(String(r.txId || ""));
                }
                color: (lez.sendResult && lez.sendResult.error !== undefined) ? Theme.palette.warning : Theme.palette.success
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
            }
        }
    }
}
