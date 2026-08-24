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

    // A row was clicked → open that room.
    signal activated(string topic)
    // "Start something" pressed → begin a new coordination.
    signal newActivity()

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

        LogosButton {
            objectName: "startSomethingButton"
            text: qsTr("Start something")
            onClicked: home.newActivity()
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
