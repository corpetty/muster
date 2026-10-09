import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The home surface — the app's launch screen, and its argument in one list.
//
// People come back to *do* something (pay someone, answer a request), so the
// first thing they see is the doing: an action list bucketed by what it wants
// from them — needs-you first, then in-flight, then settled. This is F-18: a
// query over intents, not a second record. Every row is a headline the module
// already reduced ("Ready to pay", "Needs your signature", "Paid"); this view
// adds no interpretation of its own.
//
// PURE-RENDER: data in via `actions`, navigation out via `activated` /
// `newActivity`. It calls no backend and holds no state — the host wires the
// query to the fold and routes the signals.
//
// NB (ADR-011): nix build does not evaluate QML; a stray key or type blanks the
// whole view invisibly. Restricted to Theme keys + the Logos.Controls types
// Room.qml / Walkthrough.qml already prove render (LogosText, LogosButton).
Item {
    id: home

    // A parsed array of rows, already sorted by the host:
    //   { topic, title, action, state, detail, atMs }
    // where `action` is the plain-language headline and `state` is one of
    // "needs" | "waiting" | "settled" | "idle". Defaults to [] so a delegate
    // never faces undefined.
    property var actions: []

    // Room invites received on this identity's inbox: [{topic, from, fromAlias, note, ts}].
    // Someone opened a room WITH you and it reached your instance — shown at the top so
    // you can join without being told a name out-of-band. Defaults to [] for the delegate.
    property var invites: []

    // A row was clicked → open that room.
    signal activated(string topic)
    // "Start something" pressed → begin a new coordination.
    signal newActivity()
    // First run under the platform (exo-d4d.6): what is missing before money can move,
    // {show, title, detail, action: "accounts" | "settings"}. Empty = nothing to set up.
    property var setup: ({})
    signal manageAccounts()
    signal openSettings()
    // A received invite's Join was clicked → open (and ask to join) that room.
    signal joinInvite(string topic)
    // join a room by the code someone shared (exo-dcc.28)
    signal joinCode(string topic)
    // A received invite's Dismiss was clicked → clear it so it stops showing.
    signal dismissInvite(string topic)

    // How many rows are waiting on the user — the number worth a heading.
    readonly property int needsCount: {
        var n = 0;
        var rows = home.actions || [];
        for (var i = 0; i < rows.length; ++i)
            if (rows[i] && rows[i].state === "needs")
                n += 1;
        return n;
    }

    // The state band down the left of each row: the accent when it wants you,
    // green when it is done, a muted line otherwise — read at a glance without
    // parsing the words.
    function bandColor(state) {
        if (state === "needs")
            return Theme.palette.warning;
        if (state === "settled")
            return Theme.palette.success;
        return Theme.palette.borderDefault;
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.spacing.large
        spacing: Theme.spacing.medium

        // The heading answers "why am I here" before the list does.
        LogosText {
            Layout.fillWidth: true
            text: home.needsCount > 0
                  ? qsTr("%1 waiting on you").arg(home.needsCount)
                  : qsTr("Nothing waiting on you")
            color: home.needsCount > 0 ? Theme.palette.text : Theme.palette.textTertiary
            font.family: Theme.typography.publicSans
            font.pixelSize: Theme.typography.subtitleText
            font.weight: Theme.typography.weightBold
            elide: Text.ElideRight
        }

        // ── getting set up (a fresh install, exo-d4d.6) ─────────────────────
        // Muster never makes keys or chains: each step hands off to the app that owns it.
        Rectangle {
            objectName: "homeSetup"
            visible: !!home.setup.show
            Layout.fillWidth: true
            implicitHeight: setupCol.implicitHeight + 2 * Theme.spacing.medium
            radius: Theme.spacing.radiusMedium
            color: Theme.palette.surface
            border.width: 1
            border.color: Theme.palette.warning
            ColumnLayout {
                id: setupCol
                anchors.fill: parent
                anchors.margins: Theme.spacing.medium
                spacing: Theme.spacing.small
                LogosText {
                    text: String(home.setup.title || "")
                    color: Theme.palette.text
                    font.weight: Theme.typography.weightBold
                }
                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: String(home.setup.detail || "")
                    color: Theme.palette.textSecondary
                    font.pixelSize: Theme.typography.secondaryText
                }
                RowLayout {
                    LogosButton {
                        objectName: "homeSetupAction"
                        text: home.setup.action === "accounts" ? qsTr("Create or import an account")
                                                               : qsTr("Open Settings")
                        onClicked: home.setup.action === "accounts" ? home.manageAccounts() : home.openSettings()
                    }
                }
            }
        }

        LogosButton {
            objectName: "startSomethingButton"
            text: qsTr("Start something")
            onClicked: home.newActivity()
        }

        // ── join with a room code (exo-dcc.28) ────────────────────────────
        // Someone shared a room's code (the room's "Copy room code"): join it from here,
        // whatever room is open. Joining asks the room's members to let you in.
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.small
            LogosTextField {
                id: codeField
                objectName: "homeRoomCodeField"
                Layout.fillWidth: true
                placeholderText: qsTr("Have a room code? Paste it here")
            }
            LogosButton {
                objectName: "homeJoinCodeButton"
                text: qsTr("Join")
                enabled: codeField.text.trim().length > 0
                onClicked: { home.joinCode(codeField.text.trim()); codeField.text = ""; }
            }
        }

        // ── invitations ───────────────────────────────────────────────────
        // Someone opened a room with you; it arrived on your inbox. Join opens it
        // (and auto-asks to join). Shown only when there are any.
        ColumnLayout {
            Layout.fillWidth: true
            visible: (home.invites || []).length > 0
            spacing: Theme.spacing.tiny

            LogosText {
                text: qsTr("Invitations")
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.secondaryText
                font.weight: Theme.typography.weightBold
            }

            Repeater {
                model: home.invites || []
                delegate: Rectangle {
                    required property var modelData
                    Layout.fillWidth: true
                    implicitHeight: inviteBody.implicitHeight + 2 * Theme.spacing.medium
                    radius: Theme.spacing.radiusSmall
                    color: Theme.palette.surfaceRaised
                    border.width: 1
                    border.color: Theme.palette.warning

                    RowLayout {
                        id: inviteBody
                        anchors.fill: parent
                        anchors.margins: Theme.spacing.medium
                        spacing: Theme.spacing.small

                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: {
                                var who = String(modelData.fromAlias || "").length > 0
                                    ? String(modelData.fromAlias)
                                    : String(modelData.from || "someone").substring(0, 10) + "…";
                                var n = String(modelData.note || "");
                                return who + qsTr(" invited you to a room")
                                     + (n.length > 0 ? "  ·  " + n : "");
                            }
                            color: Theme.palette.text
                            font.pixelSize: Theme.typography.secondaryText
                        }

                        LogosButton {
                            objectName: "joinInviteButton"
                            text: qsTr("Join")
                            onClicked: home.joinInvite(String(modelData.topic || ""))
                        }

                        LogosButton {
                            objectName: "dismissInviteButton"
                            text: qsTr("Dismiss")
                            variant: LogosButton.Variant.Secondary
                            onClicked: home.dismissInvite(String(modelData.topic || ""))
                        }
                    }
                }
            }
        }

        // ── the action list (or the empty state) ──────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Theme.spacing.radiusMedium
            color: Theme.palette.surface
            border.width: 1
            border.color: Theme.palette.borderSubtle

            // Nothing on yet — the invitation, centered, standing in for the list.
            LogosText {
                anchors.centerIn: parent
                width: parent.width - 2 * Theme.spacing.large
                visible: (home.actions || []).length === 0
                text: qsTr("Nothing on yet. Start something with someone.")
                color: Theme.palette.textTertiary
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.secondaryText
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
            }

            ListView {
                id: actionList
                objectName: "actionList"
                anchors.fill: parent
                anchors.margins: Theme.spacing.small
                clip: true
                spacing: Theme.spacing.tiny
                model: home.actions

                delegate: Rectangle {
                    id: row
                    width: actionList.width
                    implicitHeight: rowBody.implicitHeight + 2 * Theme.spacing.medium
                    radius: Theme.spacing.radiusSmall
                    color: rowHover.containsMouse
                           ? Theme.palette.surfaceRaised
                           : Theme.palette.surface

                    // Clicking anywhere on the row opens its room.
                    MouseArea {
                        id: rowHover
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: home.activated(modelData ? String(modelData.topic || "") : "")
                    }

                    RowLayout {
                        id: rowBody
                        anchors.fill: parent
                        anchors.margins: Theme.spacing.medium
                        spacing: Theme.spacing.small

                        // The state band — a column the eye can scan, not five
                        // separate marks.
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredWidth: 3
                            Layout.preferredHeight: 34
                            radius: 1.5
                            color: home.bandColor(modelData ? modelData.state : "idle")
                            opacity: (modelData && modelData.state === "idle") ? 0.4 : 1.0
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            // The headline: what there is to do.
                            LogosText {
                                Layout.fillWidth: true
                                text: modelData ? String(modelData.action || "") : ""
                                color: Theme.palette.text
                                font.family: Theme.typography.publicSans
                                font.pixelSize: Theme.typography.primaryText
                                font.weight: Theme.typography.weightBold
                                elide: Text.ElideRight
                            }

                            // "title · detail" — whose it is and why it sits here.
                            LogosText {
                                Layout.fillWidth: true
                                text: {
                                    var t = modelData ? String(modelData.title || "") : "";
                                    var d = modelData ? String(modelData.detail || "") : "";
                                    return d.length > 0 ? (t + "  ·  " + d) : t;
                                }
                                color: Theme.palette.textSecondary
                                font.family: Theme.typography.publicSans
                                font.pixelSize: Theme.typography.secondaryText
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }
    }
}
