import QtQuick
import Logos.Theme
import Logos.Controls

// Where something stands, in a word or three (exo-720.5): "Needs you", "2 of 3 agreed",
// "Final". The tone, not the words, carries the colour, so a driver's own wording (U-7)
// sits on the same pill:
//   needs     waits on you           settled   done
//   waiting   waits on others        refused   blocked or refused
//   info      left the room (U-2)    warning   needs attention, not blocked
Rectangle {
    id: pill

    property string text: ""
    property string tone: "waiting"

    readonly property color fg: tone === "needs" ? MusterStyle.needsText
                              : tone === "settled" ? MusterStyle.settled
                              : tone === "refused" ? MusterStyle.refused
                              : tone === "warning" ? MusterStyle.warning
                              : tone === "info" ? MusterStyle.infoText
                              : Theme.palette.textSecondary
    readonly property color bg: tone === "needs" ? MusterStyle.needsSoft
                              : tone === "settled" ? MusterStyle.settledSoft
                              : tone === "refused" ? MusterStyle.refusedSoft
                              : tone === "warning" ? MusterStyle.warningSoft
                              : tone === "info" ? MusterStyle.infoSoft
                              : MusterStyle.neutralSoft

    implicitHeight: 22
    implicitWidth: label.implicitWidth + 18
    radius: height / 2
    color: bg
    visible: text.length > 0
    Accessible.role: Accessible.StaticText
    Accessible.name: text

    LogosText {
        textFormat: Text.PlainText
        id: label
        anchors.centerIn: parent
        text: pill.text
        color: pill.fg
        font.pixelSize: MusterStyle.badge
        font.weight: Theme.typography.weightBold
    }
}
