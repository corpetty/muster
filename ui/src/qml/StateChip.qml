import QtQuick

// Status pill (prototype `.state`). `variant`: accent | wait | settled | alarm.
// Presentational only.
Rectangle {
    id: chip
    property string text: ""
    property string variant: "accent"

    implicitHeight: label.implicitHeight + 6
    implicitWidth: label.implicitWidth + 14
    radius: Theme.radius.chip
    color: chip.variant === "settled" ? Theme.palette.settledSoft
         : chip.variant === "alarm"   ? Theme.palette.alarmSoft
         : chip.variant === "wait"    ? Theme.palette.waitSoft
         :                              Theme.palette.accentSoft

    Text {
        id: label
        anchors.centerIn: parent
        text: chip.text
        font.family: Theme.typography.mono
        font.pixelSize: Theme.typography.labelSize
        color: chip.variant === "settled" ? Theme.palette.settled
             : chip.variant === "alarm"   ? Theme.palette.alarm
             : chip.variant === "wait"    ? Theme.palette.textMuted
             :                              Theme.palette.accent
    }
}
