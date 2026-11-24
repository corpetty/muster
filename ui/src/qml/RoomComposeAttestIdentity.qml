import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Which identity backs an attestation (exo-720.3, moved verbatim out of
// RoomComposer.qml). `room` is the Room, as before the move.
// attest: WHAT identity backs your attestation. An EIP-191 attestation
// is a personal_sign with your secp256k1 AUTHORIZATION key — the same
// key that signs Safe transactions, NOT the encryption identity that
// names you in the room. Recognized signers are the Safe owners, so this
// says plainly whether your attestation will count (else it's silently
// rejected). The same disclosure the Safe composer makes, for Attest.
Rectangle {
    required property var room

    objectName: "roomAttestContext"
    visible: room.policyKind === "eip191"
    Layout.fillWidth: true
    implicitHeight: attestCtx.implicitHeight + 2 * Theme.spacing.small
    radius: Theme.spacing.radiusSmall
    color: Theme.palette.surfaceRaised
    border.width: 1
    border.color: (room.roomAccount && room.roomAccount.isSigner)
                  ? Theme.palette.success : Theme.palette.warning

    ColumnLayout {
        id: attestCtx
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.spacing.small
        anchors.rightMargin: Theme.spacing.small
        spacing: 2

        LogosText {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: qsTr("You sign with your account key, the one that signs Safe "
                     + "transactions, not your chat identity.")
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.caption
        }
        LogosText {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: qsTr("signing as %1")
                  .arg(String((room.roomAccount && room.roomAccount.actingAs) || "…"))
            color: Theme.palette.textTertiary
            font.family: MusterStyle.mono
            font.pixelSize: MusterStyle.caption
            elide: Text.ElideMiddle
        }
        LogosText {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: {
                if (!room.roomAccount || room.roomAccount.isSigner === undefined)
                    return qsTr("checking whether the room recognizes your account…");
                return room.roomAccount.isSigner
                     ? qsTr("✓ the room recognizes this account (a Safe owner) — your approval counts")
                     : qsTr("⚠ the room doesn't recognize this account, so your approval "
                          + "won't count. It recognizes: %1.")
                       .arg(String(room.roomAccount.signerSet || "the Safe owners"));
            }
            color: (room.roomAccount && room.roomAccount.isSigner)
                   ? Theme.palette.success : Theme.palette.warning
            font.family: MusterStyle.mono
            font.pixelSize: MusterStyle.caption
        }
    }
}
