import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The composer's policy picker (exo-720.3, moved verbatim out of RoomComposer.qml): THIS
// proposal's driver, one button per policy the kind can settle by (invariant 6). `room`
// is the Room, as before the move.
// ── policy picker: THIS proposal's driver (invariant 6) ───────
// Policy binds to the intent, not the room — so this picks the driver
// for the NEXT thing you propose; a card already collecting keeps its
// own. The same propose/contribute/fold runs under either. Safe =
// EIP-712 / secp owners; Threshold = k-of-n Ed25519 endorsement.
RowLayout {
    required property var room

    // an action carries its own driver (invoke) — no policy choice to make.
    visible: room.composeType !== "action"
    Layout.fillWidth: true
    spacing: Theme.spacing.small

    LogosText {
        textFormat: Text.PlainText
        text: room.composeType === "payment" ? qsTr("Settles via")
            : room.composeType === "split" ? qsTr("Settles on")
            : qsTr("Endorse with")
        color: Theme.palette.textTertiary
        font.family: MusterStyle.mono
        font.pixelSize: MusterStyle.caption
        font.weight: Theme.typography.weightMedium
    }

    // One button per kind that serves this proposal, from the module's one
    // kind list (exo-a50.1.2). An admitted kind is selectable; one the room
    // has not admitted (e.g. "unanimous", n-of-n) is offered as a governance
    // proposal to add it — driver-as-proposal (invariant 6). objectName
    // keeps the roomPolicy<Kind> names the UI harness clicks.
    // each button as wide as its name ("Split privately (LEZ)", "Bitcoin
    // (P2WSH)"…), wrapping onto a second line rather than truncating a name
    Flow {
        Layout.fillWidth: true
        spacing: Theme.spacing.small
    Repeater {
        model: room.policiesForKind(room.composeType)
        delegate: ActionButton {
            required property var modelData
            readonly property var info: room.kindInfo(modelData)
            // on a send, the rail by its asset alone ("Bitcoin", not "Split (Bitcoin)", exo-dcc.33)
            readonly property var sendNames: ({ "evm-split": qsTr("Ethereum or a token"), "lez-split": qsTr("LEZ, privately"),
                                                "btc-split": qsTr("Bitcoin"), "monero-split": qsTr("Monero") })
            readonly property string label: (room.composeType === "split" && room.splitSend && sendNames[String(modelData)])
                                            ? sendNames[String(modelData)]
                                            : info && info.label ? String(info.label) : String(modelData)
            objectName: "roomPolicy" + String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
            text: room.hasDriver(modelData) ? label : qsTr("＋ Propose %1").arg(label.toLowerCase())
            variant: room.shownKind === modelData
                     ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
            onClicked: {
                if (!room.backend) return;
                if (room.hasDriver(modelData)) {
                    room.pickedKind = String(modelData);
                    room.backend.setPolicy(modelData);
                }
                else   // propose admitting it — the room approves, then it appears
                    room.backend.proposeInRoom(JSON.stringify({ effect: "add-driver", kind: modelData }));
            }
        }
    }
    }

    LogosText {
        textFormat: Text.PlainText
        text: room.policy && room.policy.threshold !== undefined
              ? qsTr("%1 needed").arg(room.policy.threshold) : ""
        color: Theme.palette.textTertiary
        font.family: MusterStyle.mono
        font.pixelSize: MusterStyle.caption
    }
}
