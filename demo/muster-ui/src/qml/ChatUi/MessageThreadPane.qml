pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The message thread: a header naming the conversation, the message list (newest
// at the bottom, natively bottom-anchored) and the composer. Data in via
// properties, the composed message out via messageSubmitted.
Rectangle {
    id: root

    required property var messageModel
    required property bool currentIsGroup
    required property string title
    // Group description shown under the title; empty for direct conversations
    // and unnamed groups.
    property string description: ""
    required property string conversationId
    // The conversation's avatar identity, from the store.
    property string avatarInitials: ""
    property int avatarRamp: 0
    // The roster behind the header's facepile.
    property var memberModel: null
    property int memberCount: 0
    // Invited but not yet committed by the group; they cannot read anything
    // yet, which the scope line says rather than counting them as readers.
    property int pendingMemberCount: 0
    // What is in flight in this conversation, as a headline for the header.
    property string action: ""
    // Whether the details panel the header's toggle opens is showing.
    property bool detailsShown: false
    required property bool hasConversation
    // Whether any conversation exists at all. Optional so the pane stands alone;
    // drives the empty-thread guidance when nothing is selected.
    property bool hasConversations: true
    required property bool online
    // Whether the message model already holds this conversation's messages. It
    // does not for as long as a selection is being loaded, and the rows standing
    // in the model meanwhile are the ones left behind by the previous
    // conversation.
    required property bool ready

    signal messageSubmitted(string text)

    // Whether the wallet can act yet; a card's buttons say so rather than
    // failing when pressed.
    property bool walletReady: false
    // Raised by a card in the thread — answering a request for an address, or
    // paying one that arrived.
    signal shareAddressRequested
    signal payRequested(string toAddress, int addressForm, string assetName, string label)
    // The proposals in this conversation, folded by the backend. Handed to
    // every card so one read serves the whole thread.
    property var intents: []
    // The one the room is currently about, for the pinned banner.
    property var liveIntent: null

    // Bring the live proposal's card into view. The banner is a pointer, not a
    // second place to act, so this scrolls to the card rather than duplicating
    // its buttons — there is one set of controls for a decision.
    function showLiveIntent() {
        if (!root.liveIntent || !root.messageModel)
            return;
        const row = root.messageModel.rowOfIntent(String(root.liveIntent.intentId || ""));
        if (row >= 0)
            threadList.positionViewAtIndex(row, ListView.Center);
    }
    // Raised by a proposal card: put a payment to the room, weigh in on one,
    // abandon one, or pay one that has reached its threshold.
    signal proposeRequested(string toAddress, int addressForm, string assetName, string label)
    signal approveRequested(string intentId)
    signal dropRequested(string intentId)
    signal submitRequested(string intentId)
    // The composer's "ask for an address" action.
    signal addressRequested
    // Requests the conversation's details; emitted from the header's toggle.
    signal detailsRequested

    // Whether the thread may render its rows.
    readonly property bool threadReady: root.hasConversation && root.ready

    // Per-conversation composer drafts, restored on switch so an unsent message
    // is never carried into (or sent to) a different conversation.
    property var _drafts: ({})
    onConversationIdChanged: {
        composer.text = root._drafts[root.conversationId] || "";
        // Opening a conversation is asking to write in it.
        if (root.conversationId !== "")
            composer.takeFocus();
    }
    // Any wait for the thread gets the grace before a placeholder, and any
    // arrival gets the settle window, whether it came from a switch or from the
    // models being refetched under the same conversation.
    onThreadReadyChanged: {
        if (root.threadReady)
            settleTimer.restart();
        else
            graceTimer.restart();
    }

    // Put a message the backend refused back in the composer, unless the user
    // has already started typing the next one.
    function restoreFailedSend(conversationId, content) {
        if (conversationId === root.conversationId && composer.text === "")
            composer.text = content;
    }

    // Exposed for the exchange doc-test's inspector hooks.
    property alias messageCount: threadList.count

    implicitWidth: 400
    radius: Theme.spacing.radiusXlarge
    color: Theme.palette.background
    border.width: 1
    border.color: Theme.palette.borderSubtle
    clip: true

    // A switch that resolves quickly should not flash a placeholder, so the
    // thread stays blank until this elapses.
    Timer {
        id: graceTimer
        interval: 150
    }

    // The message model is a separate replica from the properties carrying the
    // selection, so its rows can land a moment after the conversation counts as
    // loaded. Wait that out before calling a thread empty.
    Timer {
        id: settleTimer
        interval: 300
    }

    // One menu serves every row: a thread holds far more messages than the menu
    // has entries.
    LogosMenu {
        id: messageMenu
        objectName: "messageMenu"

        // What the Copy entry puts on the clipboard, set by the row that asked
        // for the menu.
        property string copyText: ""

        LogosMenuItem {
            objectName: "copyMessageMenuItem"
            //: Menu entry that copies a message
            text: qsTr("Copy")
            onTriggered: clipboard.copy(messageMenu.copyText)
        }
    }

    ClipboardProxy {
        id: clipboard
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ThreadHeader {
            Layout.fillWidth: true
            visible: root.hasConversation
            title: root.title
            description: root.description
            isGroup: root.currentIsGroup
            avatarInitials: root.avatarInitials
            avatarRamp: root.avatarRamp
            memberModel: root.memberModel
            memberCount: root.memberCount
            pendingMemberCount: root.pendingMemberCount
            online: root.online
            action: root.action
            detailsShown: root.detailsShown
            onDetailsToggled: root.detailsRequested()
        }

        // U-3: what the room is deciding, held above the thread so it is in
        // view before anyone scrolls for it. Sits under the header, where the
        // scope line already qualifies everything below.
        PinnedIntent {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.spacing.medium
            Layout.rightMargin: Theme.spacing.medium
            Layout.topMargin: Theme.spacing.tiny
            visible: root.hasConversation && active
            intent: root.liveIntent
            onReviewRequested: root.showLiveIntent()
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ListView {
                id: threadList
                objectName: "threadList"
                anchors.fill: parent
                clip: true
                reuseItems: true
                model: root.messageModel
                spacing: Theme.spacing.tiny
                verticalLayoutDirection: ListView.BottomToTop
                visible: root.threadReady

                header: Item {
                    height: Theme.spacing.medium
                }
                footer: Item {
                    height: Theme.spacing.medium
                }

                ScrollBar.vertical: LogosScrollBar {}

                delegate: MessageDelegate {
                    width: ListView.view.width
                    groupContext: root.currentIsGroup
                    walletReady: root.walletReady
                    intents: root.intents
                    onContextMenuRequested: function (text) {
                        messageMenu.copyText = text;
                        messageMenu.popup();
                    }
                    onShareAddressRequested: root.shareAddressRequested()
                    onPayRequested: function (toAddress, addressForm, assetName, label) {
                        root.payRequested(toAddress, addressForm, assetName, label);
                    }
                    onProposeRequested: function (toAddress, addressForm, assetName, label) {
                        root.proposeRequested(toAddress, addressForm, assetName, label);
                    }
                    onApproveRequested: function (intentId) {
                        root.approveRequested(intentId);
                    }
                    onDropRequested: function (intentId) {
                        root.dropRequested(intentId);
                    }
                    onSubmitRequested: function (intentId) {
                        root.submitRequested(intentId);
                    }
                }
            }

            MessageSkeleton {
                objectName: "threadSkeleton"
                anchors.fill: parent
                visible: root.hasConversation && !root.ready && !graceTimer.running
            }

            EmptyState {
                objectName: "threadEmptyState"
                anchors.centerIn: parent
                width: parent.width - 2 * Theme.spacing.large
                visible: threadList.count === 0 && (!root.hasConversation || (root.threadReady && !settleTimer.running))
                text: root.hasConversation ? qsTr("No messages yet") : root.hasConversations ? qsTr("Select a conversation to start chatting") : qsTr("No conversations yet. Use New chat in the sidebar to start one.")
            }
        }

        MessageComposer {
            id: composer
            objectName: "composer"
            Layout.fillWidth: true
            Layout.leftMargin: Theme.spacing.xlarge
            Layout.rightMargin: Theme.spacing.xlarge
            Layout.topMargin: Theme.spacing.tiny
            Layout.bottomMargin: Theme.spacing.large
            //: Placeholder in the composer, naming the conversation it sends to
            placeholder: root.title !== "" ? qsTr("Message %1").arg(root.title) : qsTr("Type a message...")
            // Name the reason the composer is closed: being connected with
            // nothing selected is not the same as having no connection.
            disabledPlaceholder: root.online ? qsTr("Select a conversation to start chatting") : qsTr("Chat not connected")
            submitEnabled: root.online && root.hasConversation
            onSubmitted: function (text) {
                root.messageSubmitted(text);
            }
            onAddressRequested: root.addressRequested()
            // Persist the in-progress text (and clear it after a send, when the
            // field empties) against the current conversation.
            onTextChanged: if (root.conversationId !== "")
                root._drafts[root.conversationId] = composer.text
        }
    }
}
