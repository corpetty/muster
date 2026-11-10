import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// A savings circle's rounds from the pot (exo-267.3, coordination/circle.nim), under the
// charter that sets them: each round every member pays their share into the circle's LEZ
// multisig, and the round's recipient is paid the pot by the members' vote. The list is the
// module's (coordinate_circle), polled while shown. A pay-in counts only when the chain holds
// it; a missed one keeps its round open and names who has not paid.
ColumnLayout {
    id: rc
    required property var backend
    spacing: Theme.spacing.small

    readonly property var view: {
        try { return JSON.parse(rc.backend ? (rc.backend.circleJson || "{}") : "{}"); }
        catch (e) { return {}; }
    }
    readonly property bool running: rc.view.ok === true
    readonly property var names: rc.view.memberNames || ({})
    readonly property var result: {
        var r = rc.backend ? String(rc.backend.circleResultJson || "") : "";
        if (r.length === 0) return {};
        try { return JSON.parse(r); } catch (e) { return {}; }
    }
    function nameOf(id) { var n = rc.names[id]; return n ? String(n) : (String(id).slice(0, 8) + "…"); }
    // base units → LEZ as an exact decimal string (9 decimals), never through a float
    function lez(base) {
        var t = String(base || "0").replace(/^0+(?=[0-9])/, "");
        if (!/^[0-9]+$/.test(t)) return "?";
        while (t.length < 10) t = "0" + t;
        var whole = t.slice(0, t.length - 9), frac = t.slice(t.length - 9).replace(/0+$/, "");
        return frac.length > 0 ? whole + "." + frac : whole;
    }
    function paidLine(rd) {
        var counted = (rd.payIns || []).filter(function (p) { return p.standing === "included"; }).map(function (p) { return rc.nameOf(p.member); });
        return counted.length > 0 ? qsTr("Paid in: %1").arg(counted.join(", ")) : qsTr("Nobody has paid in yet");
    }
    function pendingPayout(round) {
        return (rc.view.payouts || []).some(function (p) { return p.round === round && p.onSchedule && p.state !== "final"; });
    }

    Timer {
        interval: 3000; repeat: true; triggeredOnStart: true
        running: rc.visible && rc.backend !== null
        onTriggered: rc.backend.loadCircle()
    }

    SectionHeader {
        Layout.fillWidth: true
        visible: rc.running
        text: rc.view.complete ? qsTr("Rounds: the cycle is complete") : qsTr("Rounds: round %1 is due").arg(rc.view.current)
    }
    LogosText {
        visible: rc.running
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: Theme.palette.textSecondary
        font.pixelSize: MusterStyle.caption
        text: qsTr("Each round every member pays %1 LEZ into the pot, and one member is paid %2 LEZ by the members' vote. The pot holds %3 LEZ now. A payment counts once the chain shows it came from an account its member shared here.")
              .arg(rc.lez(rc.view.share)).arg(rc.lez(rc.view.pot)).arg(rc.view.vaultBalance ? rc.lez(rc.view.vaultBalance) : "?")
    }
    Repeater {
        model: rc.running ? rc.view.rounds : []
        delegate: ColumnLayout {
            id: rowRound
            required property var modelData
            readonly property bool due: modelData.round === rc.view.current
            readonly property bool iOwe: (modelData.missing || []).indexOf(rc.view.me) >= 0
            Layout.fillWidth: true
            spacing: 2
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: rowRound.due ? Theme.palette.text : Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
                font.weight: rowRound.due ? Theme.typography.weightBold : Theme.typography.weightRegular
                text: qsTr("Round %1 pays %2%3").arg(modelData.round).arg(rc.nameOf(modelData.recipient))
                      .arg(modelData.settled ? qsTr(" · paid out") : "")
            }
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                visible: !modelData.settled
                color: (modelData.missing || []).length > 0 ? Theme.palette.warning : Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
                text: (modelData.missing || []).length > 0
                      ? rc.paidLine(modelData) + qsTr(" · not yet: %1").arg(modelData.missing.map(rc.nameOf).join(", "))
                      : qsTr("Everyone has paid in")
            }
            RowLayout {
                visible: !modelData.settled
                ActionButton {
                    objectName: "circlePayIn_" + modelData.round
                    visible: rowRound.iOwe
                    enabled: (rc.view.myAccounts || []).length > 0
                    text: qsTr("Pay my share")
                    onClicked: rc.backend.circlePayIn(String(modelData.round))
                }
                ActionButton {
                    objectName: "circlePayout_" + modelData.round
                    visible: rowRound.due && (modelData.missing || []).length === 0 && !rc.pendingPayout(modelData.round)
                    text: qsTr("Propose the payout")
                    variant: LogosButton.Variant.Secondary
                    onClicked: rc.backend.proposeCirclePayout(String(modelData.round))
                }
            }
        }
    }
    LogosText {
        visible: rc.running && (rc.view.myAccounts || []).length === 0 && !rc.view.complete
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: Theme.palette.textSecondary
        font.pixelSize: MusterStyle.caption
        text: qsTr("To pay in, share a LEZ account of your own with the room first (Accounts).")
    }
    InlineNotice {
        objectName: "circleResult"
        Layout.fillWidth: true
        visible: rc.result.error !== undefined || rc.result.tx !== undefined || rc.result.pending !== undefined
        tone: rc.result.error !== undefined ? "error" : "waiting"
        title: rc.result.error !== undefined ? qsTr("That did not work") : qsTr("On its way to the chain")
        text: rc.result.error !== undefined ? String(rc.result.detail || rc.result.error) : String(rc.result.detail || "")
    }
}
