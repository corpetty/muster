import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The room's scope panel: who is in the room, and the boundary line that says
// how far what you type reaches. U-1/U-9 — the membership roster and the scope
// are drawn on the same surface, because they are the same question asked twice:
// "who can see this" is just "who is in the room" read from the reader's side.
//
// Pure-render. Everything it shows arrives as properties (the parsed roster and
// the topic); the one thing it can do — ask to grow the room — leaves as a
// signal. It calls no backend and holds no state; the host wires addMember() to
// the coordination surface and feeds the fold back in through `members`.
//
// The scope copy is not decoration: adding someone re-keys the room forward
// (F-16), so a new member reads from their epoch on and never the log before it.
// The panel says that in words at the moment the roster is about to change,
// which is the only moment it matters (U-6).
//
// NB (ADR-011): nix build does not evaluate QML, so a stray type or Theme key
// blanks the whole view invisibly. This restricts itself to the Theme keys and
// Logos.Controls types Main.qml / Room.qml already prove render.
Item {
    id: scope

    // The parsed roster: [{ identity, self }], identity a 64-byte hex string.
    // A parse failure upstream yields [] (absent), never fiction.
    property var members: []

    // The room topic — the thing the scope is drawn around.
    property string topic: ""

    // Asks the host to grow the room; the host collects the new member's key.
    signal addMember()

    // The roster, guarded to an array so length and the Repeater are always safe.
    readonly property var roster: scope.members ? scope.members : []

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight + 2 * Theme.spacing.large
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: column
            x: Theme.spacing.large
            y: Theme.spacing.large
            width: flick.width - 2 * Theme.spacing.large
            spacing: Theme.spacing.large

            // ── In the room ───────────────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small

                LogosText {
                    Layout.fillWidth: true
                    text: qsTr("In the room")
                    color: Theme.palette.text
                    font.family: Theme.typography.publicSans
                    font.pixelSize: Theme.typography.subtitleText
                    font.weight: Theme.typography.weightBold
                    elide: Text.ElideRight
                }

                // Count-first, like the scope line: a number to check against the
                // room, not a word to skim past.
                LogosText {
                    text: qsTr("%1").arg(scope.roster.length)
                    color: Theme.palette.textTertiary
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.badgeText
                    font.weight: Theme.typography.weightMedium
                }
            }

            // ── the roster ────────────────────────────────────────────────────
            // A Repeater over the parsed array, not a nested ListView-in-Layout
            // (which mis-sizes inside a ColumnLayout). One card per member.
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small

                Repeater {
                    model: scope.roster

                    delegate: Rectangle {
                        id: memberCard
                        objectName: "memberRow"
                        // Tap to reveal the full 64-byte identity. Collapsed by
                        // default (a short handle scans), expanded when the reader
                        // wants to check the exact key that can read the room.
                        property bool revealed: false
                        Layout.fillWidth: true
                        implicitHeight: memberRow.implicitHeight + 2 * Theme.spacing.medium
                        radius: Theme.spacing.radiusSmall
                        color: Theme.palette.surfaceRaised
                        border.width: 1
                        border.color: Theme.palette.borderSubtle

                        RowLayout {
                            id: memberRow
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Theme.spacing.medium
                            anchors.rightMargin: Theme.spacing.medium
                            spacing: Theme.spacing.small

                            // A short, stable handle for a 64-byte hex identity,
                            // marked where it is this account. A member with no
                            // identity reads "unknown" rather than blank.
                            LogosText {
                                Layout.fillWidth: true
                                text: {
                                    var id = modelData && modelData.identity
                                        ? String(modelData.identity) : "";
                                    var label = id.length > 0
                                        ? (memberCard.revealed ? id : id.substring(0, 10) + "…")
                                        : qsTr("unknown");
                                    return modelData && modelData.self
                                        ? label + qsTr(" · you") : label;
                                }
                                color: Theme.palette.text
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.secondaryText
                                font.weight: Theme.typography.weightMedium
                                wrapMode: memberCard.revealed ? Text.WrapAnywhere : Text.NoWrap
                                elide: memberCard.revealed ? Text.ElideNone : Text.ElideRight
                            }

                            // The role tag. For now everyone in the room is a
                            // signer; "reads only" exists so the seam is drawn
                            // before a driver ever fills it.
                            LogosText {
                                text: qsTr("signer")
                                color: Theme.palette.textTertiary
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                            }
                        }

                        // Tap anywhere on the card to reveal / re-collapse the full
                        // identity. Above the row (text is inert), so the whole card
                        // is the target; the pointer cursor signals it.
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: memberCard.revealed = !memberCard.revealed
                        }
                    }
                }
            }

            // The one action that grows the room, pinned under the roster. The
            // module has the join/admit handshake (coordinate_request_join /
            // coordinate_pending / coordinate_admit), but it is not yet wired to a
            // UI surface — so this stays disabled rather than a dead click, and says
            // why. The addMember() signal is kept for when the surface lands.
            LogosButton {
                objectName: "addMemberButton"
                Layout.fillWidth: true
                text: qsTr("Add someone")
                enabled: false
                onClicked: scope.addMember()
            }

            LogosText {
                Layout.fillWidth: true
                text: qsTr("Growing the room needs the join handshake wired to a surface — it lands with the live delivery node.")
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.badgeText
                wrapMode: Text.WordWrap
            }

            // ── Scope ─────────────────────────────────────────────────────────
            LogosText {
                Layout.fillWidth: true
                text: qsTr("Scope")
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.subtitleText
                font.weight: Theme.typography.weightBold
                elide: Text.ElideRight
            }

            // The boundary line. A live dot for the present-tense claim beside
            // it, then count-first: "N can read" is a number to check, where
            // "end-to-end" is a phrase people have learned to skim.
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small

                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: 6
                    Layout.preferredHeight: 6
                    radius: 3
                    color: Theme.palette.success
                }

                LogosText {
                    Layout.fillWidth: true
                    text: qsTr("end-to-end · %1 can read").arg(scope.roster.length)
                    color: Theme.palette.textSecondary
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.badgeText
                    elide: Text.ElideRight
                }
            }

            // Why growing the room is a boundary change, not a settings toggle
            // (F-16). Said here because here is where the roster changes.
            LogosText {
                Layout.fillWidth: true
                text: qsTr("Adding someone re-keys the room forward — they read from here on, never earlier.")
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.secondaryText
                wrapMode: Text.WordWrap
            }
        }
    }
}
