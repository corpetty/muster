import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Quests (exo-267.8, docs/design/lez-quest-program.md): quests this room issues through its
// LEZ multisig. Issuing and closing are proposals the room votes on, like any LEZ multisig
// action; they appear in the thread as cards. Taking and confirming are a person's own
// transactions, from their own LEZ account. The list is the module's (coordinate_quests):
// the room's quests, each record as the chain reads it now, the terms only when the room
// holds text that hashes to what the record commits to. This view polls while shown and
// says what the chain shows to anyone.
ColumnLayout {
    id: qv
    required property var backend
    property var room: null
    spacing: Theme.spacing.medium

    readonly property var listed: {
        try { return JSON.parse(qv.backend ? (qv.backend.questsJson || "[]") : "[]"); }
        catch (e) { return []; }
    }
    readonly property var quests: Array.isArray(qv.listed) ? qv.listed : []
    readonly property string listError: Array.isArray(qv.listed) ? "" : String(qv.listed.error || "")
    readonly property string listDetail: Array.isArray(qv.listed) ? "" : String(qv.listed.detail || "")
    readonly property var result: {
        var r = qv.backend ? String(qv.backend.questResultJson || "") : "";
        if (r.length === 0) return {};
        try { return JSON.parse(r); } catch (e) { return {}; }
    }
    readonly property bool onMultisig: qv.room !== null && String(qv.room.policyKind || "") === "lez-multisig"

    function short(h) { h = String(h || ""); return h.length > 16 ? h.slice(0, 8) + "…" + h.slice(-6) : h; }
    function statusText(s) {
        if (s === "open") return qsTr("Open: waiting for its taker");
        if (s === "accepted") return qsTr("Taken: waiting for its confirmer");
        if (s === "confirmed") return qsTr("Confirmed done: the room can close it and pay");
        if (s === "closed") return qsTr("Closed: the taker was paid");
        if (s === "cancelled") return qsTr("Withdrawn: the bounty went back to the pot");
        if (s === "not on chain") return qsTr("Proposed: not on chain until the room's vote executes");
        return qsTr("The chain could not be read just now");
    }

    Timer {
        interval: 3000; repeat: true; triggeredOnStart: true
        running: qv.visible && qv.backend !== null
        onTriggered: qv.backend.loadQuests()
    }

    LogosText {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: Theme.palette.textSecondary
        font.pixelSize: MusterStyle.caption
        text: qsTr("A quest is issued by the room's LEZ multisig: the room votes to open it, and its bounty moves from the pot into the quest's record. Its taker accepts and its confirmer confirms, each from their own account. The room votes again to close it and pay the taker.")
    }

    InlineNotice {
        Layout.fillWidth: true
        visible: qv.listError.length > 0
        tone: qv.listError === "no-quest-program" ? "needs" : "waiting"
        title: qv.listError === "no-quest-program" ? qsTr("No quest program is set") : qsTr("Quests are not available")
        text: qv.listError === "no-quest-program"
              ? qsTr("Set Settings → lez-quest-program to the quest program's account on this LEZ zone.")
              : qv.listDetail
    }

    // ── issue ──────────────────────────────────────────────────────────────
    SectionHeader { Layout.fillWidth: true; text: qsTr("Issue a quest") }
    InlineNotice {
        Layout.fillWidth: true
        visible: !qv.onMultisig
        tone: "needs"
        title: qsTr("Quests are issued from a LEZ multisig")
        text: qsTr("Choose the room's LEZ multisig account (Accounts) as what the room acts from.")
    }
    ColumnLayout {
        Layout.fillWidth: true
        enabled: qv.onMultisig && qv.listError.length === 0
        spacing: Theme.spacing.small
        LogosTextField {
            id: taskField
            objectName: "questTask"
            Layout.fillWidth: true
            placeholderText: qsTr("What is to be done")
        }
        RowLayout {
            Layout.fillWidth: true
            LogosTextField {
                id: bountyField
                objectName: "questBounty"
                Layout.preferredWidth: 160
                placeholderText: qsTr("Bounty (LEZ base units)")
            }
            LogosTextField {
                id: confirmerField
                objectName: "questConfirmer"
                Layout.fillWidth: true
                placeholderText: qsTr("Confirmer's LEZ account: who says it is done")
            }
        }
        LogosTextField {
            id: takerField
            objectName: "questTaker"
            Layout.fillWidth: true
            placeholderText: qsTr("Taker's LEZ account (empty: anyone but the confirmer may take it)")
        }
        ActionButton {
            objectName: "questIssue"
            text: qsTr("Propose issuing it")
            enabled: taskField.text.trim().length > 0 && /^[0-9]+$/.test(bountyField.text.trim())
                     && confirmerField.text.trim().length > 0
            onClicked: {
                var t = { task: taskField.text.trim(), bounty: bountyField.text.trim(),
                          confirmer: confirmerField.text.trim() };
                if (takerField.text.trim().length > 0) t.taker = takerField.text.trim();
                qv.backend.proposeQuest(JSON.stringify(t));
            }
        }
        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.caption
            text: qsTr("The task's text stays in this room; the chain holds only its hash. Approving the proposal approves the quest program by its account: any program the multisig calls with the pot's seed can move the pot.")
        }
    }

    InlineNotice {
        objectName: "questResult"
        Layout.fillWidth: true
        visible: qv.result.error !== undefined || qv.result.pending !== undefined || qv.result.ok !== undefined
        tone: qv.result.error !== undefined || qv.result.ok === false ? "error"
              : qv.result.ok === true ? "ok" : "waiting"
        title: qv.result.error !== undefined ? qsTr("That did not work")
             : qv.result.ok === true ? qsTr("Verified from the chain")
             : qv.result.ok === false ? qsTr("Not verified")
             : qsTr("On its way to the chain")
        text: {
            var r = qv.result;
            if (r.error !== undefined) return String(r.error) + (r.detail ? ": " + r.detail : "");
            if (r.ok === true)
                return qsTr("Issued by %1, taken by %2, confirmed by %3; %4 of %5 current members approved the close.")
                       .arg(qv.short(r.issuer)).arg(qv.short(r.taker)).arg(qv.short(r.confirmer))
                       .arg(r.approvals).arg(r.threshold);
            if (r.ok === false) return String(r.why || "");
            return String(r.detail || "");
        }
    }

    // ── the room's quests ────────────────────────────────────────────────────
    SectionHeader { Layout.fillWidth: true; text: qsTr("This room's quests"); count: String(qv.quests.length) }
    LogosText {
        visible: qv.quests.length === 0
        color: Theme.palette.textSecondary
        font.pixelSize: MusterStyle.caption
        text: qsTr("No quests yet.")
    }
    RowLayout {
        Layout.fillWidth: true
        visible: qv.quests.length > 0
        LogosTextField {
            id: accountField
            objectName: "questAccount"
            Layout.fillWidth: true
            placeholderText: qsTr("Your LEZ account, to take or confirm a quest")
            text: (qv.room && qv.room.lezMember && qv.room.lezMember.account) ? String(qv.room.lezMember.account) : ""
        }
        ActionButton {
            objectName: "questUseMine"
            text: qsTr("Use mine")
            variant: LogosButton.Variant.Secondary
            onClicked: qv.backend.lezMemberAccount("")
        }
    }
    Repeater {
        model: qv.quests
        delegate: ColumnLayout {
            id: row
            required property var modelData
            required property int index
            readonly property string st: String(modelData.chain || "")
            Layout.fillWidth: true
            spacing: Theme.spacing.small

            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: Theme.palette.text
                font.pixelSize: MusterStyle.body
                font.weight: Theme.typography.weightBold
                text: row.modelData.termsFound ? String(row.modelData.terms.task)
                                               : qsTr("A quest whose terms this room does not hold")
            }
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
                text: qsTr("%1 · bounty %2 · confirmer %3%4")
                      .arg(qv.statusText(row.st)).arg(row.modelData.bounty)
                      .arg(qv.short(row.modelData.confirmer || (row.modelData.terms ? row.modelData.terms.confirmer : "")))
                      .arg(row.modelData.taker ? " · taker " + qv.short(row.modelData.taker) : "")
            }
            RowLayout {
                Layout.fillWidth: true
                ActionButton {
                    objectName: "questAccept_" + row.index
                    visible: row.st === "open" && row.modelData.iMayAccept === true
                    enabled: accountField.text.trim().length > 0
                    text: qsTr("Take it")
                    onClicked: qv.backend.questAccept(row.modelData.questId, accountField.text.trim())
                }
                ActionButton {
                    objectName: "questConfirm_" + row.index
                    visible: row.st === "accepted" && row.modelData.iConfirm === true
                    enabled: accountField.text.trim().length > 0
                    text: qsTr("Confirm it is done")
                    onClicked: qv.backend.questConfirm(row.modelData.questId, accountField.text.trim())
                }
                ActionButton {
                    objectName: "questClose_" + row.index
                    visible: row.st === "confirmed" && String(row.modelData.closeIntent || "") === "" && qv.onMultisig
                    text: qsTr("Propose closing it and paying")
                    onClicked: qv.backend.proposeQuestClose(row.modelData.questId)
                }
                ActionButton {
                    objectName: "questCancel_" + row.index
                    visible: (row.st === "open" || row.st === "accepted") && qv.onMultisig
                    text: qsTr("Propose withdrawing it")
                    variant: LogosButton.Variant.Secondary
                    onClicked: qv.backend.proposeQuestCancel(row.modelData.questId)
                }
                ActionButton {
                    objectName: "questVerify_" + row.index
                    visible: row.st === "closed" && row.modelData.createKey !== undefined && Number(row.modelData.closeIndex) > 0
                    text: qsTr("Verify from the chain")
                    variant: LogosButton.Variant.Secondary
                    onClicked: qv.backend.verifyQuest(JSON.stringify({
                        record: row.modelData.record, createKey: row.modelData.createKey,
                        closeIndex: Number(row.modelData.closeIndex), multisigProgram: row.modelData.multisigProgram }))
                }
            }
            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.palette.borderSubtle }
        }
    }

    // ── what the chain shows ─────────────────────────────────────────────────
    SectionHeader { Layout.fillWidth: true; text: qsTr("Who sees what") }
    LogosText {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: Theme.palette.textSecondary
        font.pixelSize: MusterStyle.caption
        text: qsTr("Anyone can read a quest's record on the LEZ chain: the pot that issued it, its bounty, its confirmer's and taker's accounts, its status and the hash of its terms, and every vote that opened and closed it. "
                 + "Nobody can be named as taker or confirmer without signing it themselves. "
                 + "The task's text, and who the people behind those accounts are, stay in this room until its members publish them.")
    }
}
