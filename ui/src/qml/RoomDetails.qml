import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls
import Logos.Icons

// Room details, on demand (exo-720.8, docs/design/ui-modernization.md §4 U4): the room's
// meta-state, which used to be a 320 px column always on screen, now a drawer closed by
// default. Four tabs, the same components and the same folds of the sealed log as before:
//   People    who is in the room, who asks to join, the room's security level (ScopePanel)
//   Accounts  the accounts members disclosed into the room, and the forms to add one
//   FileShare files shared in the room, sealed, moved by Logos Storage (exo-4d0)
//   Quests    quests the room's LEZ multisig issues and closes, taken and confirmed by
//             people's own accounts (exo-267.8)
//   History   how the room reached its state (ActivityFeed)
//   Privacy   who can see what (FlowView); the store node is always listed (FS-9)
// Its connections moved to the header's dot (RoomHeader). The Room decides where the drawer
// sits — beside the thread when there is room, over it when not — and what opens it: the
// header, the scope line, a refusal that names an account (exo-dcc.30), a join request.
Rectangle {
    id: details
    required property var room   // the Room this piece belongs to (Room.qml's roomItem)

    readonly property var tabs: ["people", "accounts", "files", "quests", "history", "privacy"]
    color: Theme.palette.backgroundTertiary

    Rectangle {      // the edge against the thread
        anchors.left: parent.left
        width: 1; height: parent.height
        color: Theme.palette.borderSubtle
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 1
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 56
            Layout.leftMargin: Theme.spacing.large
            Layout.rightMargin: Theme.spacing.small
            LogosText {
                Layout.fillWidth: true
                text: qsTr("Room details")
                color: Theme.palette.text
                font.pixelSize: MusterStyle.subtitle
                font.weight: Theme.typography.weightBold
            }
            IconAction {
                objectName: "roomDetailsClose"
                label: qsTr("Close room details")
                icon: LogosIcons.close
                onClicked: details.room.closeDetails()
            }
        }
        // each tab is its label's width (a TabBar otherwise splits the width evenly, and at
        // six tabs the side panel's ~60 px a tab overlapped "Accounts" and "FileShare"); past
        // the panel's width the bar flicks sideways
        LogosTabBar {
            id: tabBar
            objectName: "roomDetailsTabs"
            clip: true           // a scrolled bar stays inside the panel
            Layout.fillWidth: true
            Layout.leftMargin: Theme.spacing.small
            currentIndex: Math.max(0, details.tabs.indexOf(details.room.detailsTab))
            onCurrentIndexChanged: details.room.detailsTab = details.tabs[currentIndex]
            LogosTabButton { objectName: "roomDetailsPeople"; text: qsTr("People"); width: implicitWidth }
            LogosTabButton { objectName: "roomDetailsAccounts"; text: qsTr("Accounts"); width: implicitWidth }
            LogosTabButton { objectName: "roomDetailsFiles"; text: qsTr("FileShare"); width: implicitWidth }
            LogosTabButton { objectName: "roomDetailsQuests"; text: qsTr("Quests"); width: implicitWidth }
            LogosTabButton { objectName: "roomDetailsHistory"; text: qsTr("History"); width: implicitWidth }
            LogosTabButton { objectName: "roomDetailsPrivacy"; text: qsTr("Privacy"); width: implicitWidth }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.palette.borderSubtle }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: Theme.spacing.large
            currentIndex: tabBar.currentIndex

            // ── People ────────────────────────────────────────────────────
            ScopePanel {
                members: details.room.members
                pending: details.room.pending
                topic: details.room.topic
                joinStatus: details.room.backend ? String(details.room.backend.joinStatus || "") : ""
                founder: details.room.founded
                securityLevels: details.room.securityLevels
                onRequestJoin: if (details.room.backend) details.room.backend.requestJoin()
                onAdmit: function (identityHex) { details.room.admitMember(identityHex); }
            }

            // ── Accounts ──────────────────────────────────────────────────
            // The accounts block is taller than a window (Safe, Bitcoin, FROST and LEZ
            // multisig sections): it scrolls. When an add-an-account form opens it scrolls
            // to show it, since the forms sit at the end (exo-dcc.30).
            Flickable {
                id: accountsFlick
                clip: true
                contentWidth: width
                contentHeight: accounts.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                function showEnd() { contentY = Math.max(0, contentHeight - height); }
                Timer { id: accountsFollow; interval: 60; onTriggered: accountsFlick.showEnd() }

                // The accounts members have disclosed into this room (exo-a50.1.3).
                RoomAccounts {
                    id: accounts
                    width: accountsFlick.width
                    accounts: details.room.roomAccounts
                    // The composer was refused for want of an account this kind can act
                    // from: open the form that discloses one (exo-dcc.30).
                    wantedFamilies: {
                        var e = details.room.policyError || {};
                        if (e.error !== "no-account" || !details.room.kindNeedsAccount(details.room.policyKind)) return [];
                        var info = details.room.kindInfo(details.room.policyKind);
                        return (info && info.accountFamilies) ? info.accountFamilies : [];
                    }
                    discloseResult: details.room.discloseResult
                    suggestionAvailable: {
                        try { return JSON.parse(details.room.backend ? details.room.backend.accountJson : "{}").available !== false; }
                        catch (e) { return true; }
                    }
                    defaultChainId: {
                        try { return String(JSON.parse(details.room.backend ? details.room.backend.accountJson : "{}").defaultChainId || "31337"); }
                        catch (e) { return "31337"; }
                    }
                    lezMember: details.room.lezMember
                    lezCreate: details.room.lezCreate
                    frostCeremonies: details.room.frostCeremonies
                    frostCeremony: details.room.frostCeremony
                    onFrostOpenRequested: function (cid, network, t, n) {
                        if (details.room.backend) details.room.backend.frostCeremonyOpen(cid, network, t, n);
                    }
                    onFrostJoinRequested: function (cid) { if (details.room.backend) details.room.backend.frostCeremonyJoin(cid); }
                    lezMsigCeremonies: details.room.lezMsigCeremonies
                    lezMsigOpen: details.room.lezMsigOpen
                    lezMsigPropose: details.room.lezMsigPropose
                    lezMsigState: details.room.lezMsigState
                    lezMsigFund: details.room.lezMsigFund
                    lezMsigRecover: details.room.lezMsigRecover
                    memberAccounts: details.room.memberAccounts
                    discloseAccount: details.room.discloseAccount
                    onDiscloseMyAccountRequested: function (specJson) {
                        if (details.room.backend) details.room.backend.discloseMyAccount(specJson);
                    }
                    onRetractMyAccountRequested: function (accountId) {
                        if (details.room.backend) details.room.backend.retractMyAccount(accountId);
                    }
                    onLezMsigRecoverRequested: function (account) {
                        if (details.room.backend) details.room.backend.lezMsigRecover(account);
                    }
                    onLezMsigFundRequested: function (account, amount) {
                        if (details.room.backend) details.room.backend.lezMsigFund(account, amount);
                    }
                    onLezMsigOpenRequested: function (specJson) { if (details.room.backend) details.room.backend.lezMsigOpen(specJson); }
                    onLezMsigProposeRequested: function (account, actionJson) {
                        if (!details.room.backend) return;
                        // a proposal goes out from the room's policy: make it this multisig first
                        details.room.backend.setPolicy("lez-msig@" + account);
                        details.room.backend.lezMsigPropose(actionJson);
                    }
                    xmrMsigSetups: details.room.xmrMsigSetups
                    xmrMsigSetup: details.room.xmrMsigSetup
                    xmrMsigPropose: details.room.xmrMsigPropose
                    xmrMsigWalletSet: details.room.xmrMsigWalletSet
                    roomMembers: details.room.members
                    onXmrMsigSetupRequested: function (cid, k, membersJson) {
                        if (details.room.backend) details.room.backend.xmrMsigSetupOpen(cid, "", k, membersJson);
                    }
                    onXmrMsigJoinRequested: function (cid) { if (details.room.backend) details.room.backend.xmrMsigSetupJoin(cid); }
                    onXmrMsigProposeRequested: function (account, recipients, feeCap, memo) {
                        if (details.room.backend) details.room.backend.xmrMsigPropose(account, recipients, feeCap, memo);
                    }
                    onDiscloseRequested: function (accountJson) { if (details.room.backend) details.room.backend.discloseAccount(accountJson); }
                    onLezMemberRequested: if (details.room.backend) details.room.backend.lezMemberAccount("")
                    onLezCreateRequested: function (threshold, members) {
                        if (details.room.backend) details.room.backend.lezCreateMultisig(threshold, members);
                    }
                    onDiscloseSuggested: if (details.room.backend) details.room.backend.discloseSuggestedAccount()
                    onFormShown: accountsFollow.restart()
                }
            }

            // ── FileShare: files shared in the room (exo-4d0, docs/design/room-swarm.md) ──
            Flickable {
                clip: true
                contentWidth: width
                contentHeight: fileShare.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                RoomFileShare {
                    id: fileShare
                    objectName: "roomFileShare"
                    width: parent.width
                    backend: details.room.backend
                    room: details.room
                }
            }

            // ── Quests: issued and closed by the room's LEZ multisig (exo-267.8) ──
            Flickable {
                clip: true
                contentWidth: width
                contentHeight: quests.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                RoomQuests {
                    id: quests
                    objectName: "roomQuests"
                    width: parent.width
                    backend: details.room.backend
                    room: details.room
                }
            }

            // ── History: paramount to the education mission — the decisions that led
            // to the current state, and each update as it lands ──────────────────
            ActivityFeed {
                entries: details.room.activity
            }

            // ── Privacy: who can see what, folded from the same log (exo-002.5) ──
            Flickable {
                clip: true
                contentWidth: width
                contentHeight: privacyCol.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                ColumnLayout {
                    id: privacyCol
                    width: parent.width
                    spacing: Theme.spacing.medium
                    // one proposal's flow, from its card's "Who sees this?" — say so, and offer
                    // the whole room's
                    Rectangle {
                        objectName: "flowFilterChip"
                        visible: details.room.detailsIntent.length > 0
                        Layout.fillWidth: true
                        implicitHeight: chipRow.implicitHeight + 2 * Theme.spacing.small
                        radius: Theme.spacing.radiusLarge
                        color: MusterStyle.needsSoft
                        RowLayout {
                            id: chipRow
                            anchors.fill: parent
                            anchors.leftMargin: Theme.spacing.medium
                            anchors.rightMargin: Theme.spacing.tiny
                            LogosText {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: {
                                    var it = details.room.intentById(details.room.detailsIntent);
                                    var what = it && it.summary ? String(it.summary.text || "") : "";
                                    return what.length > 0 ? qsTr("Showing one proposal: %1").arg(what)
                                                           : qsTr("Showing one proposal");
                                }
                                color: MusterStyle.needsText
                                font.pixelSize: MusterStyle.caption
                                font.weight: Theme.typography.weightBold
                            }
                            IconAction {
                                objectName: "flowFilterClear"
                                size: 24
                                label: qsTr("Show the whole room")
                                icon: LogosIcons.close
                                onClicked: details.room.detailsIntent = ""
                            }
                        }
                    }
                    LogosText {
                        objectName: "flowOpenMap"
                        text: details.room.detailsIntent.length > 0 ? qsTr("See where this proposal's information went, on the room map")
                                                                    : qsTr("See it on the room map")
                        color: mapHover.hovered ? Theme.palette.text : Theme.palette.textSecondary
                        font.pixelSize: MusterStyle.caption
                        font.underline: true
                        HoverHandler { id: mapHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: details.room.openMap(details.room.detailsIntent.length > 0 ? "crossings" : "leaks", details.room.detailsIntent) }
                    }
                    FlowView {
                        id: flowView
                        objectName: "flowView"
                        Layout.fillWidth: true
                        flow: details.room.flow
                        intentFilter: details.room.detailsIntent
                        collapsed: false
                    }
                }
            }
        }
    }
}
