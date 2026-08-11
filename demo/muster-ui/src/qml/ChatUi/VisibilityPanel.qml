import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// "Who can see this?" — answered continuously, for wherever the conversation
// has got to, beside the thing it describes rather than in a help page nobody
// opens.
//
// Every step reached stays on screen, current one first. Sending a message
// must not cost you the explanation of how you got here: the earlier steps are
// still true, and on a first run they are the part worth reading.
//
// Each step ends with a dark disclosure block on the prototype's outside
// ground — the one place in the app where the ground changes, marking the
// boundary being crossed. Its rows are the same fields at every step so they
// can be compared; at the payment step most read "not disclosed", which is the
// argument in one table.
//
// One Repeater over a flat row list, not nested Repeaters per step. Nesting
// them (each with `required property var modelData`) shadows the outer scope in
// Qt 6 and fails by silently not loading the component — with the error
// surfacing nowhere. VisibilityClaims.rowsUpTo builds the structure instead.
Rectangle {
    id: root

    // How far the conversation has got. Everything up to it is shown.
    property string step: VisibilityClaims.stepDiscovery
    // What happened to get here, oldest first: {step, what, atMs}.
    property var trail: []

    // Bound, not called inside the Repeater's model: a plain function result is
    // evaluated once, and the panel would go on describing the step the user
    // used to be on.
    readonly property var rows: VisibilityClaims.rowsUpTo(root.step)

    color: Theme.palette.background

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        PanelHeader {
            Layout.fillWidth: true
            title: qsTr("Who can see this")
        }

        LogosScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ColumnLayout {
                width: root.width
                spacing: Theme.spacing.small

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.spacing.tiny
                }

                // ── how you got here ─────────────────────────────────────
                // Read off the conversation, so it is the thread's own account
                // of itself rather than a second record that could disagree.
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: Theme.spacing.medium
                    Layout.rightMargin: Theme.spacing.medium
                    visible: root.trail.length > 0
                    spacing: Theme.spacing.tiny

                    LogosText {
                        text: qsTr("HOW YOU GOT HERE")
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }

                    Repeater {
                        model: root.trail

                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small

                            Rectangle {
                                Layout.preferredWidth: 5
                                Layout.preferredHeight: 5
                                Layout.alignment: Qt.AlignTop
                                Layout.topMargin: 6
                                radius: 2.5
                                color: ChatTheme.settled
                            }

                            LogosText {
                                Layout.fillWidth: true
                                text: modelData.what
                                color: Theme.palette.textSecondary
                                wrapMode: Text.WordWrap
                                font.pixelSize: Theme.typography.secondaryText
                            }
                        }
                    }
                }

                // ── the steps, current first ─────────────────────────────
                Repeater {
                    model: root.rows

                    delegate: ColumnLayout {
                        id: row
                        required property var modelData

                        Layout.fillWidth: true
                        Layout.leftMargin: Theme.spacing.medium
                        Layout.rightMargin: Theme.spacing.medium
                        spacing: 2

                        // step heading
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: Theme.spacing.medium
                            visible: row.modelData.type === "step"
                            spacing: Theme.spacing.small

                            LogosText {
                                text: row.modelData.type === "step"
                                    ? row.modelData.title.toUpperCase() : ""
                                color: row.modelData.current ? Theme.palette.text
                                                             : Theme.palette.textTertiary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                                font.weight: Theme.typography.weightBold
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 1
                                color: Theme.palette.borderSubtle
                            }

                            LogosText {
                                visible: row.modelData.type === "step" && !row.modelData.current
                                text: qsTr("earlier")
                                color: Theme.palette.textTertiary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                            }
                        }

                        // claim: kind rule + label
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: Theme.spacing.small
                            visible: row.modelData.type === "claim"
                            spacing: Theme.spacing.small

                            Rectangle {
                                Layout.preferredWidth: 3
                                Layout.preferredHeight: kindLabel.implicitHeight
                                radius: 1.5
                                color: row.modelData.kind === "protects" ? ChatTheme.settled
                                     : row.modelData.kind === "gap" ? ChatTheme.alarm
                                     : Theme.palette.textTertiary
                            }

                            LogosText {
                                id: kindLabel
                                text: row.modelData.kind === "protects" ? qsTr("PROTECTED")
                                    : row.modelData.kind === "gap" ? qsTr("STILL OPEN")
                                    : qsTr("ELSEWHERE")
                                color: row.modelData.kind === "protects" ? ChatTheme.settled
                                     : row.modelData.kind === "gap" ? ChatTheme.alarm
                                     : Theme.palette.textTertiary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                                font.weight: Theme.typography.weightMedium
                            }
                        }

                        LogosText {
                            Layout.fillWidth: true
                            visible: row.modelData.type === "claim"
                            text: row.modelData.type === "claim" ? row.modelData.title : ""
                            color: Theme.palette.text
                            wrapMode: Text.WordWrap
                            font.pixelSize: Theme.typography.primaryText
                            font.weight: Theme.typography.weightMedium
                        }

                        LogosText {
                            Layout.fillWidth: true
                            visible: row.modelData.type === "claim"
                            text: row.modelData.type === "claim" ? row.modelData.body : ""
                            color: Theme.palette.textSecondary
                            wrapMode: Text.WordWrap
                            font.pixelSize: Theme.typography.secondaryText
                        }

                        // A gap naming no fix would be a complaint. The fix and
                        // its honest status are what make it a curriculum.
                        LogosText {
                            Layout.fillWidth: true
                            Layout.topMargin: 2
                            visible: row.modelData.type === "claim" && row.modelData.isGap
                            text: row.modelData.type === "claim"
                                ? qsTr("What would close it: %1").arg(row.modelData.fix) : ""
                            color: Theme.palette.textSecondary
                            wrapMode: Text.WordWrap
                            font.pixelSize: Theme.typography.secondaryText
                        }

                        LogosText {
                            Layout.fillWidth: true
                            visible: row.modelData.type === "claim" && row.modelData.isGap
                            text: row.modelData.type === "claim" ? row.modelData.statusText : ""
                            color: row.modelData.type === "claim" && row.modelData.isShipped
                                ? ChatTheme.settled : Theme.palette.textTertiary
                            wrapMode: Text.WordWrap
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }

                        LogosText {
                            Layout.fillWidth: true
                            visible: row.modelData.type === "claim" && row.modelData.evidence !== ""
                            text: row.modelData.type === "claim" ? row.modelData.evidence : ""
                            color: Theme.palette.textTertiary
                            wrapMode: Text.WordWrap
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }

                        // ── what leaves the room ─────────────────────────
                        // Drawn as banded rows rather than one block, so the
                        // flat list can render it without nesting.
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.topMargin: row.modelData.type === "disclosure-head"
                                ? Theme.spacing.small : 0
                            Layout.preferredHeight: row.modelData.type === "disclosure-head"
                                ? headText.implicitHeight + 2 * Theme.spacing.small : 0
                            visible: row.modelData.type === "disclosure-head"
                            color: ChatTheme.outside
                            topLeftRadius: Theme.spacing.radiusMedium
                            topRightRadius: Theme.spacing.radiusMedium

                            LogosText {
                                id: headText
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: Theme.spacing.small
                                anchors.rightMargin: Theme.spacing.small
                                text: row.modelData.type === "disclosure-head"
                                    ? row.modelData.caption.toUpperCase() : ""
                                color: ChatTheme.outsideAccent
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                                font.weight: Theme.typography.weightMedium
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: row.modelData.type === "disclosure-row"
                                ? discRow.implicitHeight + Theme.spacing.small : 0
                            visible: row.modelData.type === "disclosure-row"
                            color: ChatTheme.outside
                            bottomLeftRadius: row.modelData.type === "disclosure-row"
                                && row.modelData.last ? Theme.spacing.radiusMedium : 0
                            bottomRightRadius: bottomLeftRadius

                            RowLayout {
                                id: discRow
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: Theme.spacing.small
                                anchors.rightMargin: Theme.spacing.small
                                spacing: Theme.spacing.small

                                LogosText {
                                    text: row.modelData.type === "disclosure-row"
                                        ? row.modelData.label : ""
                                    color: "#96A19B"
                                    font.family: Theme.typography.mono
                                    font.pixelSize: Theme.typography.badgeText
                                }

                                Item { Layout.fillWidth: true }

                                LogosText {
                                    text: row.modelData.type === "disclosure-row"
                                        ? row.modelData.value : ""
                                    color: row.modelData.type === "disclosure-row"
                                        && row.modelData.withheld
                                        ? ChatTheme.outsideAccent : ChatTheme.outsideInk
                                    horizontalAlignment: Text.AlignRight
                                    font.family: Theme.typography.mono
                                    font.pixelSize: Theme.typography.badgeText
                                    font.weight: Theme.typography.weightMedium
                                }
                            }
                        }
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.spacing.medium
                }
            }
        }
    }
}
