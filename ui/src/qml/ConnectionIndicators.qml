import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The room's dependency indicators — the untrusted, user-chosen infrastructure it
// relies on (invariant 8): the RPC endpoint the Safe path settles through, and the
// delivery node the encrypted transport rides. Their liveness is *shown*, never
// assumed: a green dot is a live probe (connectivity), an amber one is "reachable
// but not what we expect" (e.g. the wrong chain), a red one is down. This is the
// honesty the vision asks for — the user sees what they're depending on and whether
// it is actually there.
//
// Pure-render: the only input is `status` ({rpc, delivery}); no signals out, no
// state held. A missing field reads as "unknown" (grey), never a false green.
//
// NB (ADR-011): nix build does not evaluate QML; a stray type or Theme key blanks
// the view. Restricted to Theme keys + the Logos.Controls types the room proves.
Item {
    id: conn

    // The parsed connectivity object; a parse failure upstream yields {} (unknown).
    property var status: ({})

    implicitHeight: col.implicitHeight

    // dot colour for a level string
    function levelColor(level) {
        return level === "ok" ? Theme.palette.success
             : level === "warn" ? Theme.palette.warning
             : level === "down" ? Theme.palette.error
             : Theme.palette.textTertiary;   // unknown / absent
    }

    // one entry to render, guarded — {name, level, detail} or a placeholder
    function entryOf(key, fallbackName) {
        var e = (conn.status && conn.status[key]) ? conn.status[key] : null;
        return {
            name: e && e.name ? String(e.name) : fallbackName,
            level: e && e.level ? String(e.level) : "unknown",
            detail: e && e.detail ? String(e.detail) : qsTr("checking…")
        };
    }

    ColumnLayout {
        id: col
        width: parent.width
        spacing: Theme.spacing.small

        LogosText {
            text: qsTr("Connections")
            color: Theme.palette.text
            font.family: Theme.typography.publicSans
            font.pixelSize: Theme.typography.subtitleText
            font.weight: Theme.typography.weightBold
        }

        // one row per dependency
        Repeater {
            model: [conn.entryOf("rpc", qsTr("RPC")),
                    conn.entryOf("delivery", qsTr("Delivery"))]

            delegate: RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: Theme.spacing.small

                Rectangle {
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: 5
                    Layout.preferredWidth: 8
                    Layout.preferredHeight: 8
                    radius: 4
                    color: conn.levelColor(modelData.level)
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    LogosText {
                        Layout.fillWidth: true
                        text: modelData.name
                        color: Theme.palette.text
                        font.pixelSize: Theme.typography.secondaryText
                        font.weight: Theme.typography.weightMedium
                    }
                    LogosText {
                        Layout.fillWidth: true
                        text: modelData.detail
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
