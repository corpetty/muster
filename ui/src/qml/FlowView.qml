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
// (docs/00-vision.md, FS-9). Outside observers (your RPC provider, the chain, a
// target module) are listed only once the module's matrix carries them — i.e. once a
// proposal's driver names them (exo-428); a room that only talks lists none.
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
    // One proposal's flow (exo-720.10, a card's "Who sees this?"): its intent id, else "".
    // Filtered, the matrix is rebuilt from that proposal's rows alone, over the same
    // observers the room's matrix lists — the store node always among them (FS-9).
    property string intentFilter: ""
    readonly property var allRows: (flowView.flow && flowView.flow.rows) ? flowView.flow.rows : []
    readonly property var rows: flowView.intentFilter.length === 0 ? flowView.allRows
        : flowView.allRows.filter(function (r) { return String(r.intentId || "") === flowView.intentFilter; })
    readonly property var roomMatrix: (flowView.flow && flowView.flow.matrix) ? flowView.flow.matrix : ({})
    readonly property var matrix: {
        if (flowView.intentFilter.length === 0) return flowView.roomMatrix;
        var m = {};
        for (var o in flowView.roomMatrix) m[o] = [];
        for (var i = 0; i < flowView.rows.length; ++i) {
            var r = flowView.rows[i], to = String(r.to || ""), f = String(r.field || "");
            if (!(to in m)) m[to] = [];
            if (f.length > 0 && m[to].indexOf(f) < 0) m[to].push(f);
        }
        for (var k in m) m[k].sort();
        return m;
    }

    readonly property var observerOrder: ["room-member", "store-node", "rpc-provider", "chain-observer", "target-module",
                                          "storage-peer", "storage-dht"]
    function observerLabel(o) {
        return o === "room-member" ? qsTr("the room")
             : o === "store-node" ? qsTr("the store node")
             : o === "rpc-provider" ? qsTr("your RPC provider")
             : o === "chain-observer" ? qsTr("anyone reading the chain")
             : o === "target-module" ? qsTr("the module it calls")
             : o === "storage-peer" ? qsTr("storage nodes that serve or fetch it")
             : o === "storage-dht" ? qsTr("anyone reading the storage network") : String(o);
    }
    // A field or a kind the module names in its own words, said in ours where it has a
    // hyphen in it (a voice note's, docs/design/voice-notes.md §10); any other as it comes.
    function fieldWord(f) {
        return f === "voice-note" ? qsTr("voice note")
             : f === "voice-note-length" ? qsTr("voice note length")
             : f === "fixed-size" ? qsTr("one fixed size") : String(f);
    }
    function kindWord(k) {
        return k === "voice" ? qsTr("voice note") : k === "file" ? qsTr("shared file") : String(k);
    }
    function matrixEntries() {
        var out = [];
        for (var i = 0; i < flowView.observerOrder.length; ++i) {
            var o = flowView.observerOrder[i];
            if (!(o in flowView.matrix)) continue;   // not introduced by any proposal
            var fields = flowView.matrix[o] || [];
            out.push({ to: o, label: flowView.observerLabel(o),
                       fields: fields.length > 0 ? fields.map(flowView.fieldWord).join(", ") : qsTr("nothing yet") });
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
                font.pixelSize: MusterStyle.caption
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
                font.pixelSize: MusterStyle.caption
            }
            // handlers, not a MouseArea: an Item here would be a layout cell (and a spacing gap)
            TapHandler { onTapped: flowView.collapsed = !flowView.collapsed }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
        }

        // ── the expandable body, bounded + scrollable ─────────────────────
        // The observer matrix and (on demand) the per-action rows can run to many
        // lines; kept inside a height-capped Flickable so a long flow scrolls in
        // place instead of ballooning the whole side column off the screen.
        Flickable {
            id: bodyFlick
            visible: !flowView.collapsed
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(body.implicitHeight, 300)
            contentWidth: width
            contentHeight: body.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: body
                width: bodyFlick.width
                spacing: Theme.spacing.tiny

                // observer matrix
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
                            font.pixelSize: MusterStyle.caption
                            font.weight: Theme.typography.weightMedium
                        }
                        LogosText {
                            objectName: "flowFields_" + String(modelData.to)
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: modelData.fields
                            color: Theme.palette.text
                            font.family: MusterStyle.mono
                            font.pixelSize: MusterStyle.caption
                        }
                    }
                }

                // per-action rows, on demand
                ActionButton {
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
                        text: "#" + String(modelData.seq) + " " + flowView.kindWord(String(modelData.kind))
                            + (modelData.intentId ? " " + flowView.shortId(modelData.intentId) : "")
                            + " · " + flowView.fieldWord(String(modelData.field)) + " → " + flowView.observerLabel(modelData.to)
                            + (modelData.to === "room-member" && modelData.members && modelData.members.length > 0
                                 ? " (" + modelData.members.map(flowView.shortId).join(", ") + ")" : "")
                            + " · epoch " + String(modelData.epoch)
                            + (modelData.declared === false ? qsTr("  ⚠ undeclared") : "")
                        color: modelData.to === "room-member" ? Theme.palette.textSecondary : Theme.palette.warning
                        font.family: MusterStyle.mono
                        font.pixelSize: MusterStyle.caption
                    }
                }
            }
        }
    }
}
