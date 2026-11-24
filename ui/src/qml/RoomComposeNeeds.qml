import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// What the composer's selected kind needs from your own modules (exo-720.3, moved
// verbatim out of RoomComposer.qml; exo-dcc.10). `room` is the Room, as before the move.
// What the selected kind needs from your own modules and does not have yet
// (exo-dcc.10), each with "Install …" where installing would help: Muster
// asks Basecamp's Package Manager, and you confirm the install there. The
// kind stays on the list above. Propose waits only when a need of your own
// part is definitely missing; a need Muster cannot judge only warns.
ColumnLayout {
    required property var room

    objectName: "composeNeeds"
    // a Monero send's payer needs no Monero module: they pay from any wallet (exo-dcc.32)
    visible: room.composeType !== "action" && room.composeNeeds.length > 0
             && !(room.composeType === "split" && room.splitSend && room.splitMonero)
    Layout.fillWidth: true
    spacing: Theme.spacing.tiny

    Repeater {
        model: room.composeType !== "action" ? room.composeNeeds : []
        delegate: ColumnLayout {
            id: composeNeed
            required property var modelData
            readonly property string pkg: room.needPkg(composeNeed.modelData)
            readonly property var req: room.packageReq(composeNeed.pkg)
            readonly property string note: room.installNote(composeNeed.pkg, composeNeed.modelData)
            readonly property bool installable: room.needCanInstall(composeNeed.modelData)
            Layout.fillWidth: true
            spacing: 2

            LogosText {
                textFormat: Text.PlainText
                objectName: "composeNeed_" + String(composeNeed.modelData.name || "")
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: room.composeNeedLine(composeNeed.modelData)
                color: Theme.palette.warning
                font.pixelSize: MusterStyle.caption
            }
            // no Install button (installed but not running, starting,
            // failed, or nothing to install): the module's own remedy
            LogosText {
                textFormat: Text.PlainText
                visible: !composeNeed.installable && String(composeNeed.modelData.remedy || "").length > 0
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("To fix: ") + String(composeNeed.modelData.remedy || "")
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
            }
            RowLayout {
                visible: composeNeed.installable || !!(composeNeed.req && composeNeed.req.state === "failed")
                spacing: Theme.spacing.small
                ActionButton {
                    objectName: "composeNeedInstall_" + String(composeNeed.modelData.name || "")
                    visible: composeNeed.installable
                    enabled: !(composeNeed.req && composeNeed.req.state === "asking")
                    text: qsTr("Install %1").arg(String(composeNeed.modelData.install || ""))
                    variant: LogosButton.Variant.Secondary
                    onClicked: room.askInstall(composeNeed.modelData)
                }
                // not in any enabled catalogue: show it in Package Manager
                ActionButton {
                    objectName: "composeInstallShow_" + composeNeed.pkg
                    visible: !!(composeNeed.req && composeNeed.req.state === "failed")
                    text: qsTr("Open Package Manager")
                    variant: LogosButton.Variant.Secondary
                    onClicked: room.packageShowRequested(composeNeed.pkg)
                }
            }
            LogosText {
                textFormat: Text.PlainText
                objectName: "composeInstallStatus_" + composeNeed.pkg
                visible: composeNeed.note.length > 0
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: composeNeed.note
                color: (composeNeed.req && (composeNeed.req.state === "open" || composeNeed.req.state === "asking"))
                       ? Theme.palette.textSecondary : Theme.palette.warning
                font.pixelSize: MusterStyle.caption
            }
            LogosText {
                textFormat: Text.PlainText
                visible: !!(composeNeed.req && composeNeed.req.state === "failed" && composeNeed.req.showError)
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                // "failed": Package Manager opened, but found no such package
                text: String((composeNeed.req && composeNeed.req.showError) || "") === "failed"
                      ? qsTr("Package Manager opened, but could not find %1. Check its catalogues.").arg(composeNeed.pkg)
                      : qsTr("Package Manager could not be opened (%1). Open it from Basecamp.")
                        .arg(String((composeNeed.req && composeNeed.req.showError) || ""))
                color: Theme.palette.warning
                font.pixelSize: MusterStyle.caption
            }
        }
    }

    // why Propose is off — or, when Muster cannot tell, that it is not
    LogosText {
        textFormat: Text.PlainText
        objectName: "composeNeedsGate"
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        // Propose also waits while the module takes a newly picked policy (pickPending):
        // there is no missing module to name then (exo-c4f: "until  runs here.")
        text: room.composeBlockers.length > 0
              ? qsTr("Propose is off until %1 runs here.")
                    .arg(room.composeBlockers.map(function (n) { return String(n.name || ""); }).join(", "))
              // a switch the module refused never completes (exo-408 item 10): say so, and why,
              // rather than "waits" — the policy still in force is the previous one
              : room.pickPending && room.policyError && room.policyError.error !== undefined
              ? qsTr("Propose is off: this proposal could not switch to %1. %2")
                    .arg(((room.kindInfo(room.pickedKind) || {}).label) || room.pickedKind)
                    .arg(room.chainErrorWords(String(room.policyError.error), room.policyError.detail)
                         || String(room.policyError.error))
              : room.pickPending
              ? qsTr("Propose waits while this proposal switches to %1.")
                    .arg(((room.kindInfo(room.pickedKind) || {}).label) || room.pickedKind)
              : qsTr("You can still propose.")
        color: room.composeBlocked ? Theme.palette.warning : Theme.palette.textTertiary
        font.pixelSize: MusterStyle.caption
    }
}
