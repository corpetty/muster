import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The room's dependency indicators — the untrusted, user-chosen infrastructure it
// relies on (invariant 8), and ONLY what it relies on (exo-428). The room's own
// baseline is the delivery node its encrypted transport rides; everything else is
// dictated by the drivers: a proposal whose driver declares it (a Safe proposal: the
// RPC and the chain it must serve) INTRODUCES the connection, and the row says which
// proposal brought it in. A room that only talks or decides shows no RPC at all.
// Liveness is *shown*, never assumed: green is a live probe, amber is "reachable but
// not what the proposal needs" (e.g. the wrong chain), red is down, grey is unknown
// (an undeclared driver's needs, or a probe this host can't run).
//
// Pure-render: the only input is `status` ({rows:[{key,name,level,detail,source,
// endpoint?,remedy?,introducedBy:[{intentId,policy}]}]}); no signals out, no state
// held. Nothing loaded yet reads as the delivery row "checking…", never a false green.
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

    // a policy kind as the room names it
    function policyName(p) {
        return p === "safe" ? qsTr("Safe")
             : p === "eip191" ? qsTr("EIP-191")
             : p === "frost" ? qsTr("FROST")
             : String(p || qsTr("unknown"));
    }

    // why this row is here: the room's own transport, or the proposal(s) that need it
    function whyOf(e) {
        if (e.source === "room") return qsTr("the room's own transport");
        var who = Array.isArray(e.introducedBy) ? e.introducedBy : [];
        if (who.length === 0) return qsTr("introduced by a proposal");
        var first = who[0];
        var id = String(first.intentId || "");
        var shortId = id.length > 10 ? id.slice(0, 10) + "…" : id;
        return who.length === 1
            ? qsTr("introduced by a %1 proposal · %2").arg(conn.policyName(first.policy)).arg(shortId)
            : qsTr("introduced by %1 proposals (first: %2 · %3)").arg(who.length)
                  .arg(conn.policyName(first.policy)).arg(shortId);
    }

    // the rows to render, guarded — the module's driver-dictated list, or a
    // placeholder delivery row until the first probe lands
    function entries() {
        var rows = (conn.status && Array.isArray(conn.status.rows)) ? conn.status.rows : [];
        if (rows.length === 0)
            return [{ name: qsTr("Delivery"), level: "unknown", detail: qsTr("checking…"),
                      why: qsTr("the room's own transport"), remedy: "" }];
        var out = [];
        for (var i = 0; i < rows.length; ++i) {
            var e = rows[i] || {};
            var detail = e.detail ? String(e.detail) : qsTr("checking…");
            if (e.endpoint) detail = String(e.endpoint) + " · " + detail;
            out.push({ name: e.name ? String(e.name) : String(e.key || "?"),
                       level: e.level ? String(e.level) : "unknown",
                       detail: detail,
                       why: conn.whyOf(e),
                       remedy: e.remedy ? String(e.remedy) : "" });
        }
        return out;
    }

    // true when the room depends on nothing beyond its own transport
    readonly property bool baselineOnly: {
        var rows = (conn.status && Array.isArray(conn.status.rows)) ? conn.status.rows : [];
        for (var i = 0; i < rows.length; ++i) if (rows[i] && rows[i].source !== "room") return false;
        return true;
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

        // one row per dependency the room actually has
        Repeater {
            model: conn.entries()

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
                    LogosText {
                        Layout.fillWidth: true
                        text: modelData.why
                        color: Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.badgeText
                        wrapMode: Text.WordWrap
                    }
                    LogosText {
                        Layout.fillWidth: true
                        visible: modelData.remedy.length > 0
                        text: modelData.remedy
                        color: Theme.palette.warning
                        font.pixelSize: Theme.typography.badgeText
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }

        // the education line: nothing outside the room until a proposal needs it
        LogosText {
            Layout.fillWidth: true
            visible: conn.baselineOnly
            text: qsTr("Nothing outside the room yet. A proposal brings in what its driver needs, such as an RPC for a Safe payment.")
            color: Theme.palette.textTertiary
            font.pixelSize: Theme.typography.badgeText
            wrapMode: Text.WordWrap
        }
    }
}
