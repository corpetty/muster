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

    // Join-requests not yet admitted: [{ identity, bindsOwner }], identity a
    // 64-byte hex. A parse failure upstream yields [] (absent), never fiction.
    property var pending: []

    // Asks the host to grow the room; the host collects the new member's key.
    signal addMember()

    // Announce our key into this topic so an existing member can admit us
    // (coordinate_request_join). The host wires this to the module.
    signal requestJoin()

    // Admit one asker by its 64-byte identity hex (coordinate_admit): the host
    // re-keys the room forward, so the joiner reads from its epoch on (F-16).
    signal admit(string identityHex)

    // The room's active null-ladder level on the three axes (exo-1ec.5): the parsed
    // {axes:[{axis,rung,real,mechanism}]}. Guarded to an array so the Repeater is safe.
    property var securityLevels: ({})
    readonly property var securityAxes: (scope.securityLevels && scope.securityLevels.axes)
                                        ? scope.securityLevels.axes : []

    // The roster, guarded to an array so length and the Repeater are always safe.
    readonly property var roster: scope.members ? scope.members : []

    // The pending list, guarded the same way.
    readonly property var pendingList: scope.pending ? scope.pending : []

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

            // ── Security level (the null ladder, exo-1ec.5) ────────────────────
            // The room's active level on three axes — who is speaking (authentication),
            // where it came from (provenance), who can read it (confidentiality). Each
            // shows its rung (a green dot = the real level, a dim dot = the null still in
            // place) and the named mechanism. A level is never a silent fallback; the
            // module refuses a failed upgrade. Hidden until the room reports one.
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                visible: scope.securityAxes.length > 0

                LogosText {
                    Layout.fillWidth: true
                    text: qsTr("Security level")
                    color: Theme.palette.text
                    font.family: Theme.typography.publicSans
                    font.pixelSize: Theme.typography.subtitleText
                    font.weight: Theme.typography.weightBold
                    elide: Text.ElideRight
                }

                Repeater {
                    model: scope.securityAxes

                    delegate: RowLayout {
                        id: axisRow
                        required property var modelData
                        readonly property bool isReal: !!(axisRow.modelData && axisRow.modelData.real)
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small

                        // rung dot: green when the real level is active, dim when the null
                        // is still in place (a null is shown, not alarmed — it can be a
                        // legitimate terminal, e.g. an anonymous room's authentication).
                        Rectangle {
                            Layout.alignment: Qt.AlignTop
                            Layout.topMargin: Theme.spacing.tiny
                            width: Theme.spacing.small
                            height: Theme.spacing.small
                            radius: width / 2
                            color: axisRow.isReal ? Theme.palette.success : Theme.palette.textTertiary
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: {
                                    var axis = String((axisRow.modelData && axisRow.modelData.axis) || "");
                                    var rung = axisRow.isReal ? qsTr("real") : qsTr("null");
                                    return axis + "  ·  " + rung;
                                }
                                color: Theme.palette.text
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.badgeText
                                font.weight: Theme.typography.weightMedium
                            }
                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: String((axisRow.modelData && axisRow.modelData.mechanism) || "")
                                color: Theme.palette.textTertiary
                                font.pixelSize: Theme.typography.badgeText
                            }
                        }
                    }
                }
            }

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

                            // An address-book name when we have one, else a short,
                            // stable handle for the 64-byte hex identity — marked
                            // where it is this account. Tap reveals the exact key. A
                            // member with no identity reads "unknown" rather than blank.
                            readonly property string memberAlias:
                                modelData && modelData.alias ? String(modelData.alias) : ""
                            LogosText {
                                Layout.fillWidth: true
                                text: {
                                    var id = modelData && modelData.identity
                                        ? String(modelData.identity) : "";
                                    var handle = id.length > 0
                                        ? (memberCard.revealed ? id : id.substring(0, 10) + "…")
                                        : qsTr("unknown");
                                    var label = (memberRow.memberAlias.length > 0 && !memberCard.revealed)
                                        ? memberRow.memberAlias : handle;
                                    return modelData && modelData.self
                                        ? label + qsTr(" · you") : label;
                                }
                                color: Theme.palette.text
                                font.family: (memberRow.memberAlias.length > 0 && !memberCard.revealed)
                                    ? Theme.typography.publicSans : Theme.typography.mono
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

            // Grow the room — the join/admit handshake, wired. Two instances that
            // both opened this topic each start their own single-member epoch; they
            // can't read each other until one admits the other. "Ask to join"
            // announces our key on the topic (coordinate_request_join); a member who
            // is already here sees the request below and admits it.
            LogosButton {
                objectName: "requestJoinButton"
                Layout.fillWidth: true
                text: qsTr("Ask to join this room")
                onClicked: scope.requestJoin()
            }

            // When you're the only one on the roster, you can't tell whether the room
            // is empty or someone's already here (their epoch is sealed to them until
            // they admit you). Entering already sends a join request for you — so say
            // so, and that a member here will admit you, rather than leave you guessing.
            LogosText {
                visible: scope.roster.length <= 1
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: qsTr("Only you are here so far. If someone already has this room open, "
                         + "they'll see your request and can let you in — you don't need to "
                         + "do anything else. (Asking again above re-sends the request.)")
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.badgeText
            }

            // Pending join-requests: whoever has announced their key but is not yet
            // admitted. Admitting re-keys the room forward (F-16) and hands them the
            // new epoch key — they read from here on, never the log before.
            LogosText {
                visible: scope.pendingList.length > 0
                Layout.fillWidth: true
                text: qsTr("Waiting to join")
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.subtitleText
                font.weight: Theme.typography.weightBold
                elide: Text.ElideRight
            }

            Repeater {
                model: scope.pendingList
                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosText {
                        Layout.fillWidth: true
                        readonly property string ident: modelData && modelData.identity ? String(modelData.identity) : ""
                        readonly property string alias: modelData && modelData.alias ? String(modelData.alias) : ""
                        // A named contact reads by name ("Bob wants in"); an unknown asker
                        // still shows a clipped id so the admit decision isn't blind.
                        text: (alias.length > 0
                                 ? alias
                                 : (ident.length > 14 ? ident.substring(0, 10) + "…" + ident.substring(ident.length - 4) : ident))
                              + ((modelData && modelData.bindsOwner) ? qsTr("  · owner") : "")
                        color: Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.badgeText
                        elide: Text.ElideRight
                    }

                    LogosButton {
                        text: qsTr("Admit")
                        onClicked: if (modelData && modelData.identity) scope.admit(String(modelData.identity))
                    }
                }
            }

            LogosText {
                Layout.fillWidth: true
                text: qsTr("Admitting someone re-keys the room forward — they read from here on, never the messages before (F-16).")
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
