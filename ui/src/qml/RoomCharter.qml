import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The room's charter (exo-267.1, coordination/room_charter.nim): who decides what, and how
// that changes. A charter is a proposal like any other: a founding takes force once every
// member it names agrees, an amendment once the charter in force's own members agree, as
// many as its amend rule asks. Approving happens on its card in the thread; this view
// shows the charter in force, every charter proposal's standing, and the form that writes
// one from the circle template. The list is the module's (coordinate_charter), polled
// while shown.
//
// Two kinds of rule, kept apart: the room enforces the charter (who decides it, its
// schedule and roles); the chain enforces the account it names (that multisig's own
// members and threshold). Where they disagree the view says so.
ColumnLayout {
    id: cv
    required property var backend
    property var room: null
    spacing: Theme.spacing.medium

    readonly property var view: {
        try { return JSON.parse(cv.backend ? (cv.backend.charterJson || "{}") : "{}"); }
        catch (e) { return {}; }
    }
    readonly property bool found: cv.view.found === true
    readonly property var body: cv.view.body || ({})
    readonly property var names: cv.view.memberNames || ({})
    readonly property var proposals: (cv.view.proposals || []).filter(function (p) {
        return p.standing !== "in force" && p.standing !== "replaced"; })
    readonly property var result: {
        var r = cv.backend ? String(cv.backend.charterResultJson || "") : "";
        if (r.length === 0) return {};
        try { return JSON.parse(r); } catch (e) { return {}; }
    }
    // accounts the room was shown that a circle's payouts can act from
    readonly property var accounts: (cv.room && cv.room.roomAccounts ? cv.room.roomAccounts : []).filter(function (a) {
        return a.family === "lez.multisig-program" || a.family === "evm.safe"; })

    function nameOf(id) { var n = cv.names[id]; return n ? String(n) : (String(id).slice(0, 8) + "…"); }
    function abbr(h) { h = String(h || ""); return h.length > 24 ? h.slice(0, 14) + "…" + h.slice(-6) : h; }
    function ruleText(cls, policy) {
        var p = String(policy), kind = p.split("@")[0], acct = p.indexOf("@") >= 0 ? p.slice(p.indexOf("@") + 1) : "";
        var who = kind === "charter" ? qsTr("a charter amendment, under the amend rule")
                : kind === "lez-multisig" ? qsTr("a vote of the LEZ multisig %1").arg(cv.abbr(acct))
                : kind === "safe" ? qsTr("the Safe %1's owners").arg(cv.abbr(acct))
                : p;
        return qsTr("%1 → %2").arg(cls).arg(who);
    }
    function days(sec) { var d = Number(sec) / 86400; return d === Math.floor(d) ? String(d) : d.toFixed(2); }
    function standingText(p) {
        if (p.standing === "pending")
            return p.founding ? qsTr("Founding: waits on all %1 it names (%2 so far)").arg(p.electorate.length).arg(p.approvals)
                              : qsTr("Amendment: waits on %1 of %2 (%3 so far)").arg(p.k).arg(p.electorate.length).arg(p.approvals);
        if (p.standing === "out of rule") return qsTr("Will never take force: not decided under the charter in force's rule");
        if (p.standing === "stale") return qsTr("Will never take force: amends a charter no longer in force");
        if (p.standing === "superseded") return qsTr("Another charter took force instead");
        if (p.standing === "contested") return qsTr("Contested: another group's founding names different people");
        return String(p.standing);
    }

    Timer {
        interval: 3000; repeat: true; triggeredOnStart: true
        running: cv.visible && cv.backend !== null
        onTriggered: cv.backend.loadCharter()
    }

    LogosText {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: Theme.palette.textSecondary
        font.pixelSize: MusterStyle.caption
        text: qsTr("The charter says who decides what in this room, and how that changes. It is founded when every member it names agrees, and amended only as it says it may be. You approve a charter on its card in the thread.")
    }

    InlineNotice {
        objectName: "charterContested"
        Layout.fillWidth: true
        visible: (cv.view.contested || []).length > 0
        tone: "needs"
        title: qsTr("Two foundings compete")
        text: qsTr("Groups that do not include each other each founded a charter, so neither is in force. A founding that names all of them, agreed by all of them, settles it.")
    }

    // ── the charter in force ─────────────────────────────────────────────────
    SectionHeader { Layout.fillWidth: true; text: cv.found ? qsTr("In force") : qsTr("No charter yet") }
    LogosText {
        visible: !cv.found
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: Theme.palette.textSecondary
        font.pixelSize: MusterStyle.caption
        text: qsTr("This room has no charter. Until it has one, each proposal says who decides it.")
    }
    ColumnLayout {
        objectName: "charterInForce"
        visible: cv.found
        Layout.fillWidth: true
        spacing: Theme.spacing.small
        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Theme.palette.text
            font.pixelSize: MusterStyle.body
            font.weight: Theme.typography.weightBold
            text: String(cv.body.name || "")
        }
        LogosText {
            visible: String(cv.body.purpose || "").length > 0
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.caption
            text: String(cv.body.purpose || "")
        }
        LogosText {
            objectName: "charterMembers"
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Theme.palette.text
            font.pixelSize: MusterStyle.caption
            text: qsTr("Members: %1. Changing the charter takes %2 of the %3.")
                  .arg((cv.body.members || []).map(cv.nameOf).join(", "))
                  .arg(cv.body.amend ? cv.body.amend.k : "?").arg((cv.body.members || []).length)
        }
        Repeater {
            model: Object.keys(cv.body.rules || {})
            delegate: LogosText {
                required property var modelData
                Layout.fillWidth: true
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere   // words first; a long policy id still breaks
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
                text: cv.ruleText(modelData, cv.body.rules[modelData])
            }
        }
        LogosText {
            visible: cv.body.schedule !== undefined
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.caption
            text: cv.body.schedule
                  ? qsTr("Rounds: each member pays %1 %2 every %3 days; paid out in turn to %4.")
                        .arg(cv.body.schedule.share).arg(cv.body.schedule.asset).arg(cv.days(cv.body.schedule.cadence))
                        .arg((cv.body.schedule.order || []).map(cv.nameOf).join(", then "))
                  : ""
        }
        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Theme.palette.textTertiary
            font.pixelSize: MusterStyle.caption
            text: qsTr("Changed %1 time(s) since it was founded.").arg(Math.max(0, (cv.view.history || []).length - 1))
        }
        Repeater {
            model: cv.view.problems || []
            delegate: InlineNotice {
                required property var modelData
                Layout.fillWidth: true
                tone: "waiting"
                title: qsTr("The charter and its account disagree")
                text: String(modelData) + qsTr(". The chain enforces the account's own members and threshold, whatever the charter says.")
            }
        }
    }

    // ── charter proposals not yet settled ─────────────────────────────────────
    SectionHeader { Layout.fillWidth: true; visible: cv.proposals.length > 0; text: qsTr("Proposed"); count: String(cv.proposals.length) }
    Repeater {
        model: cv.proposals
        delegate: ColumnLayout {
            required property var modelData
            Layout.fillWidth: true
            spacing: 2
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: Theme.palette.text
                font.pixelSize: MusterStyle.caption
                text: String((modelData.body && modelData.body.name) || qsTr("A charter"))
            }
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: modelData.standing === "pending" ? Theme.palette.textSecondary : Theme.palette.warning
                font.pixelSize: MusterStyle.caption
                text: cv.standingText(modelData)
            }
        }
    }

    // ── write one ────────────────────────────────────────────────────────────
    SectionHeader { Layout.fillWidth: true; text: cv.found ? qsTr("Propose a change") : qsTr("Found the room's charter") }
    LogosText {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: Theme.palette.textSecondary
        font.pixelSize: MusterStyle.caption
        text: cv.found
              ? qsTr("From the circle template, filled from the charter in force. Its %1 members decide it; it takes %2 of them.")
                    .arg((cv.body.members || []).length).arg(cv.body.amend ? cv.body.amend.k : "?")
              : qsTr("A savings circle: everyone in the room pays a share each round and is paid out in turn. Every member must agree to found it.")
    }
    LogosTextField {
        id: nameField
        objectName: "charterName"
        Layout.fillWidth: true
        placeholderText: qsTr("Name")
        text: String(cv.body.name || "")
    }
    LogosTextField {
        id: purposeField
        objectName: "charterPurpose"
        Layout.fillWidth: true
        placeholderText: qsTr("Purpose")
        text: String(cv.body.purpose || "")
    }
    // two to a row, the account on its own: at the side panel's width, three fields to a
    // row cut their placeholders short
    GridLayout {
        Layout.fillWidth: true
        columns: 2
        columnSpacing: Theme.spacing.small
        rowSpacing: Theme.spacing.small
        LogosTextField {
            id: amendField
            objectName: "charterAmendK"
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            placeholderText: qsTr("Changes take (k)")
            text: cv.body.amend ? String(cv.body.amend.k) : ""
        }
        LogosTextField {
            id: shareField
            objectName: "charterShare"
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            placeholderText: qsTr("Share per round")
            text: cv.body.schedule ? String(cv.body.schedule.share) : ""
        }
        LogosTextField {
            id: assetField
            objectName: "charterAsset"
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            placeholderText: qsTr("Asset")
            text: cv.body.schedule ? String(cv.body.schedule.asset) : "LEZ"
        }
        LogosTextField {
            id: cadenceField
            objectName: "charterCadenceDays"
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            placeholderText: qsTr("Days per round")
            text: cv.body.schedule ? cv.days(cv.body.schedule.cadence) : ""
        }
        LogosTextField {
            id: accountField
            objectName: "charterAccount"
            Layout.fillWidth: true
            Layout.columnSpan: 2
            placeholderText: qsTr("The circle's account (CAIP-10), optional")
            text: String(cv.body.account || (cv.accounts.length === 1 ? cv.accounts[0].id : ""))
        }
    }
    ActionButton {
        objectName: "charterPropose"
        text: cv.found ? qsTr("Propose this change") : qsTr("Propose founding it")
        enabled: nameField.text.trim().length > 0
                 && (amendField.text.trim().length === 0 || /^[0-9]+$/.test(amendField.text.trim()))
                 && (shareField.text.trim().length === 0 || (/^[0-9]+$/.test(shareField.text.trim())
                     && assetField.text.trim().length > 0 && Number(cadenceField.text) > 0))
        onClicked: {
            var spec = { template: "circle", name: nameField.text.trim(), purpose: purposeField.text.trim() };
            if (amendField.text.trim().length > 0) spec.amendK = Number(amendField.text.trim());
            if (accountField.text.trim().length > 0) spec.account = accountField.text.trim();
            if (shareField.text.trim().length > 0) {
                spec.share = shareField.text.trim();
                spec.asset = assetField.text.trim();
                spec.cadence = Math.round(Number(cadenceField.text) * 86400);
            }
            cv.backend.proposeCharter(JSON.stringify(spec));
        }
    }
    InlineNotice {
        objectName: "charterResult"
        Layout.fillWidth: true
        visible: cv.result.error !== undefined || cv.result.intentId !== undefined
        tone: cv.result.error !== undefined ? "error" : "ok"
        title: cv.result.error !== undefined ? qsTr("Not proposed")
             : cv.result.founding ? qsTr("Founding proposed") : qsTr("Change proposed")
        text: cv.result.error !== undefined ? String(cv.result.detail || cv.result.error)
            : qsTr("Its card is in the thread, where each member who decides it approves.")
    }
}
