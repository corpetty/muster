import QtQuick
import QtQuick.Layouts
import Logos.Theme
import Logos.Controls

// The information-flow view (docs/design/action-manifest.md M5, exo-002.5): who
// could see what, for every action the room took. Folded in the module from the
// sealed log × each action's declared disclosure × the membership at that point —
// the room's shared truth, never a per-viewer claim. Leads with the observer
// matrix (per observer class, every field it could see across the log), then the
// per-action rows on demand. The store node is always present: a view that taught
// "who can see what" and omitted the observer who sees the most would be marketing
// (docs/00-vision.md, FS-9).
//
// Pure-render: the only input is `flow` ({rows, matrix}); no signals out.
Item {
    id: flowView
    property var flow: ({ rows: [], matrix: {} })
    property bool rowsOpen: false
    // Collapsed by default: the observer matrix is several wrapping rows that otherwise
    // crowd the roster/history in the side column. The heading (with the action count)
    // stays; click it to reveal "who can see what".
    property bool collapsed: true
    readonly property var rows: (flowView.flow && flowView.flow.rows) ? flowView.flow.rows : []
    readonly property var matrix: (flowView.flow && flowView.flow.matrix) ? flowView.flow.matrix : ({})

    readonly property var observerOrder: ["room-member", "store-node", "rpc-provider", "chain-observer", "target-module"]
    function observerLabel(o) {
        return o === "room-member" ? qsTr("the room")
             : o === "store-node" ? qsTr("the store node")
             : o === "rpc-provider" ? qsTr("your RPC provider")
             : o === "chain-observer" ? qsTr("anyone reading the chain")
             : o === "target-module" ? qsTr("the module it calls") : String(o);
    }
    function matrixEntries() {
        var out = [];
        for (var i = 0; i < flowView.observerOrder.length; ++i) {
            var o = flowView.observerOrder[i];
            var fields = flowView.matrix[o] || [];
            out.push({ to: o, label: flowView.observerLabel(o),
                       fields: fields.length > 0 ? fields.join(", ") : qsTr("nothing yet") });
        }
        return out;
    }
    function shortId(s) { s = String(s || ""); return s.length > 12 ? s.slice(0, 6) + "…" + s.slice(-4) : s; }

    implicitHeight: col.implicitHeight

    ColumnLayout {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Theme.spacing.tiny

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.small
            LogosText {
                text: flowView.collapsed ? "▸" : "▾"
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.badgeText
            }
            LogosText {
                Layout.fillWidth: true
                text: qsTr("Who can see what")
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.subtitleText
            }
            LogosText {
                objectName: "flowRowCount"
                text: qsTr("%1 actions").arg(flowView.rows.length)
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.badgeText
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: flowView.collapsed = !flowView.collapsed
            }
        }

        // ── the observer matrix ──────────────────────────────────────────
        Repeater {
            model: flowView.collapsed ? [] : flowView.matrixEntries()
            delegate: RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                LogosText {
                    objectName: "flowObserver_" + String(modelData.to)
                    Layout.preferredWidth: 150
                    Layout.alignment: Qt.AlignTop
                    text: modelData.label
                    color: modelData.to === "room-member" ? Theme.palette.textSecondary : Theme.palette.warning
                    font.pixelSize: Theme.typography.badgeText
                    font.weight: Theme.typography.weightMedium
                }
                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: modelData.fields
                    color: Theme.palette.text
                    font.family: Theme.typography.mono
                    font.pixelSize: Theme.typography.badgeText
                }
            }
        }

        // ── per-action rows, on demand ───────────────────────────────────
        LogosButton {
            objectName: "flowRowsToggle"
            visible: !flowView.collapsed && flowView.rows.length > 0
            text: flowView.rowsOpen ? qsTr("Hide per-action rows") : qsTr("Show per-action rows")
            variant: LogosButton.Variant.Secondary
            onClicked: flowView.rowsOpen = !flowView.rowsOpen
        }
        Repeater {
            model: (!flowView.collapsed && flowView.rowsOpen) ? flowView.rows : []
            delegate: LogosText {
                required property var modelData
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "#" + String(modelData.seq) + " " + String(modelData.kind)
                    + (modelData.intentId ? " " + flowView.shortId(modelData.intentId) : "")
                    + " · " + String(modelData.field) + " → " + flowView.observerLabel(modelData.to)
                    + (modelData.to === "room-member" && modelData.members && modelData.members.length > 0
                         ? " (" + modelData.members.map(flowView.shortId).join(", ") + ")" : "")
                    + " · epoch " + String(modelData.epoch)
                    + (modelData.declared === false ? qsTr("  ⚠ undeclared") : "")
                color: modelData.to === "room-member" ? Theme.palette.textSecondary : Theme.palette.warning
                font.family: Theme.typography.mono
                font.pixelSize: Theme.typography.badgeText
            }
        }
    }
}
