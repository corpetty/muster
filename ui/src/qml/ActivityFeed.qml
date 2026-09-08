import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The room's history — how it reached the state you're looking at, and every update
// as it happens. This is the education seam (docs/00-vision): a member who enters a
// room mid-flight can read the story of what has been decided, from the SAME sealed
// log the cards fold from (state = reduce(log)) — it invents nothing and holds no
// state of its own. Entries arrive parsed through `entries` (coordinate_activity),
// in causal order, oldest first; the newest is at the bottom, chat-style.
//
// Pure-render: the only input is `entries`; there are no signals out. Membership
// changes (join/admit/re-key) are transport control frames, not log events, so they
// do not appear here yet — a documented follow-up.
//
// NB (ADR-011): nix build does not evaluate QML; a stray type or Theme key blanks
// the view. Restricted to Theme keys + the Logos.Controls types Room.qml proves.
Item {
    id: feed

    // The parsed activity array: [{seq, kind, intentId, account, title, detail}].
    // A parse failure upstream yields [] (absent), never fiction.
    property var entries: []
    readonly property var list: feed.entries ? feed.entries : []

    // A dot colour per transition kind — settled/ready read as success, a proposal
    // as the strong text colour, the in-between steps as muted secondary.
    function dotColor(kind) {
        return kind === "settled" ? Theme.palette.success
             : kind === "ready" ? Theme.palette.success
             : kind === "propose" ? Theme.palette.text
             : kind === "submit" ? Theme.palette.textSecondary
             : Theme.palette.textSecondary;   // approve, and anything new
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.spacing.small

        // ── heading ───────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.small

            LogosText {
                Layout.fillWidth: true
                text: qsTr("Room history")
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.subtitleText
                font.weight: Theme.typography.weightBold
                elide: Text.ElideRight
            }
            LogosText {
                text: qsTr("%1").arg(feed.list.length)
                color: Theme.palette.textTertiary
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
                font.weight: Theme.typography.weightMedium
            }
        }

        LogosText {
            Layout.fillWidth: true
            text: qsTr("How this room reached its state — folded from the shared log, as it happens.")
            color: Theme.palette.textTertiary
            font.pixelSize: Theme.typography.badgeText
            wrapMode: Text.WordWrap
        }

        // ── empty state ─────────────────────────────────────────────────────
        LogosText {
            visible: feed.list.length === 0
            Layout.fillWidth: true
            Layout.topMargin: Theme.spacing.small
            text: qsTr("No activity yet. Proposals, approvals, and settlements will appear here as they happen.")
            color: Theme.palette.textTertiary
            font.pixelSize: Theme.typography.secondaryText
            wrapMode: Text.WordWrap
        }

        // ── the timeline ────────────────────────────────────────────────────
        // Oldest first, newest at the bottom. Auto-scrolled to the bottom as
        // entries arrive, so the latest update is always in view.
        Flickable {
            id: flick
            visible: feed.list.length > 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: col.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            onContentHeightChanged: if (contentHeight > height) contentY = contentHeight - height

            ColumnLayout {
                id: col
                width: flick.width
                spacing: Theme.spacing.tiny

                Repeater {
                    model: feed.list

                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.topMargin: 2
                        spacing: Theme.spacing.small

                        // the transition dot, top-aligned to the title line
                        Rectangle {
                            Layout.alignment: Qt.AlignTop
                            Layout.topMargin: 5
                            Layout.preferredWidth: 6
                            Layout.preferredHeight: 6
                            radius: 3
                            color: feed.dotColor(String(modelData && modelData.kind || ""))
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            LogosText {
                                Layout.fillWidth: true
                                text: String((modelData && modelData.title) || "")
                                color: Theme.palette.text
                                font.pixelSize: Theme.typography.secondaryText
                                font.weight: Theme.typography.weightMedium
                                wrapMode: Text.WordWrap
                            }
                            LogosText {
                                Layout.fillWidth: true
                                visible: String((modelData && modelData.detail) || "").length > 0
                                text: String((modelData && modelData.detail) || "")
                                color: Theme.palette.textTertiary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                                wrapMode: Text.WrapAnywhere
                            }
                        }
                    }
                }
            }
        }
    }
}
