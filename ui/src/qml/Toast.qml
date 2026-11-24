import QtQuick
import Logos.Theme
import Logos.Controls

// A short confirmation that goes away by itself (exo-720.5): "Agreed — your room key signed
// it." For what succeeded only; a refusal is an InlineNotice, where it happened, and stays
// until it is dealt with. Call show(text). Anchor it where it should appear.
Rectangle {
    id: toast

    property int duration: 2400
    property string text: ""
    function show(t) { toast.text = String(t || ""); toast.opacity = 1; hideTimer.restart(); }

    implicitWidth: label.implicitWidth + 2 * Theme.spacing.large
    implicitHeight: label.implicitHeight + 2 * Theme.spacing.small + 2
    radius: Theme.spacing.radiusLarge
    color: Theme.palette.text
    opacity: 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 160 } }
    Accessible.role: Accessible.AlertMessage
    Accessible.name: text

    LogosText {
        textFormat: Text.PlainText
        id: label
        anchors.centerIn: parent
        text: toast.text
        color: Theme.palette.background
        font.pixelSize: MusterStyle.body
        font.weight: Theme.typography.weightBold
    }
    Timer { id: hideTimer; interval: toast.duration; onTriggered: toast.opacity = 0 }
}
