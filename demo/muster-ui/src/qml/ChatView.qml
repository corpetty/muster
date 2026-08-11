import QtQuick
import QtCore
import QtQuick.Layouts

import Logos.Theme

import ChatUi

// Entry view (metadata.json "view"). Instantiates the store, which is the sole
// reader of the host `logos` context property, and composes the panes, wiring
// their signals to the store's actions. All UI lives in the ChatUi module; this
// file is composition only.
Rectangle {
    id: root
    implicitWidth: 1000
    implicitHeight: 700
    color: Theme.palette.backgroundInset

    // The row the user just picked, carrying its own data so the sidebar and the
    // header move in the same frame as the click instead of waiting for the
    // backend. It stops applying as soon as the backend reports that
    // conversation loaded, from when on the store is the truth again.
    property var pendingSelection: null

    readonly property var optimisticSelection: root.pendingSelection && store.loadedConversationId !== root.pendingSelection.conversationId ? root.pendingSelection : null

    readonly property string selectedConversationId: root.optimisticSelection ? root.optimisticSelection.conversationId : store.currentConversationId
    readonly property string selectedDisplayName: root.optimisticSelection ? root.optimisticSelection.displayName : store.currentDisplayName
    readonly property string selectedDescription: root.optimisticSelection ? root.optimisticSelection.description : store.currentDescription
    readonly property bool selectedIsGroup: root.optimisticSelection ? root.optimisticSelection.isGroup : store.currentIsGroup
    readonly property string selectedAvatarInitials: root.optimisticSelection ? root.optimisticSelection.avatarInitials : store.currentAvatarInitials
    readonly property int selectedAvatarRamp: root.optimisticSelection ? root.optimisticSelection.avatarRamp : store.currentAvatarRamp
    // Whether the models hold the selected conversation's data.
    readonly property bool selectionLoaded: store.loadedConversationId === root.selectedConversationId

    // Whether the conversation's details panel is showing, toggled from the
    // thread header and left as the user last set it.
    property bool detailsShown: false

    // The newest failure the status bar is holding, and how many nobody has
    // looked at yet. Both stand until the logs are opened, which is what marks
    // them seen; the failures themselves are retained by the backend either way.
    property string lastError: ""
    property int unseenErrorCount: 0

    ChatStore {
        id: store
    }

    Connections {
        target: store
        function onErrorOccurred(message) {
            root.lastError = message;
            root.unseenErrorCount += 1;
        }
        function onSendFailed(conversationId, content) {
            threadPane.restoreFailedSend(conversationId, content);
        }
        // The backend switched somewhere else (a new conversation opening, the
        // selected one going away), which retires the pending row.
        function onCurrentConversationIdChanged() {
            if (root.pendingSelection && store.currentConversationId !== root.pendingSelection.conversationId)
                root.pendingSelection = null;
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.spacing.medium
        spacing: Theme.spacing.medium

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Theme.spacing.medium

            ColumnLayout {
                // A layout nested in a layout fills by default, which would hand
                // the sidebar the slack meant for the thread.
                Layout.fillWidth: false
                Layout.preferredWidth: 320
                Layout.minimumWidth: 260
                Layout.fillHeight: true
                spacing: Theme.spacing.medium

                // The home surface. What there is to do leads; the person it
                // is with is the context on each row.
                ActionsPane {
                    id: actionsPane
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    actions: store.actions
                    currentConversationId: root.selectedConversationId
                    online: store.online
                    onConversationSelected: function (conversationId) {
                        store.selectConversation(conversationId);
                    }
                    onNewActivityRequested: newActivityDialog.open()
                }

                AccountCard {
                    Layout.fillWidth: true
                    address: store.myAddress
                    label: store.myLabel
                    initials: store.myInitials
                    online: store.online
                    statusLabel: store.statusLabel
                }

                // Directly under the identity: in this app, what you can spend
                // is part of who you are in the conversation, not a separate
                // destination.
                WalletCard {
                    objectName: "walletCard"
                    Layout.fillWidth: true
                    ready: store.walletReady
                    busy: store.walletBusy
                    stage: store.walletStage
                    statusLabel: store.walletLabel
                    privateBalance: store.privateBalance
                    publicBalance: store.publicBalance
                    errorText: store.walletError
                    onOpenRequested: store.openWallet()
                    onFundRequested: store.fundWallet()
                    onRefreshRequested: store.refreshBalances()
                }

                // Under the wallet, so the running job sits with the thing it
                // is doing — and stays visible while the user carries on with
                // the conversation, which is the point of it being a job.
                JobStrip {
                    objectName: "jobStrip"
                    Layout.fillWidth: true
                    job: store.walletJob
                    stage: store.walletStage
                }
            }

            MessageThreadPane {
                id: threadPane
                Layout.fillWidth: true
                // The thread is what the window is for, so a window too narrow for
                // all three columns clips the right one rather than the thread.
                Layout.minimumWidth: 360
                Layout.fillHeight: true
                messageModel: store.messageModel
                currentIsGroup: root.selectedIsGroup
                title: root.selectedDisplayName
                description: root.selectedDescription
                avatarInitials: root.selectedAvatarInitials
                avatarRamp: root.selectedAvatarRamp
                conversationId: root.selectedConversationId
                memberModel: store.memberModel
                memberCount: store.memberCount
                pendingMemberCount: store.pendingMemberCount
                action: store.currentAction
                detailsShown: root.detailsShown
                hasConversation: root.selectedConversationId !== ""
                hasConversations: actionsPane.count > 0
                online: store.online
                ready: root.selectionLoaded
                walletReady: store.walletReady
                onMessageSubmitted: function (text) {
                    store.sendMessage(text);
                }
                onDetailsRequested: root.detailsShown = !root.detailsShown
                onAddressRequested: store.requestAddress()
                onShareAddressRequested: store.shareAddress()
                onPayRequested: function (keysJson, label) {
                    sendDialog.keysJson = keysJson;
                    sendDialog.peerLabel = label;
                    sendDialog.availableBalance = store.privateBalance;
                    sendDialog.open();
                }
            }

            // Always on screen, because "who can see this" is not a question
            // you ask once. Follows the conversation rather than being set
            // once, so the panel always describes what the user is doing.
            VisibilityPanel {
                objectName: "visibilityPanel"
                Layout.fillWidth: false
                Layout.preferredWidth: 300
                Layout.fillHeight: true
                step: store.journeyStep
                trail: store.journeyTrail
            }

            ColumnLayout {
                visible: root.selectedConversationId !== "" && (root.selectedIsGroup || root.detailsShown)
                Layout.fillWidth: false
                Layout.preferredWidth: 280
                Layout.fillHeight: true
                spacing: Theme.spacing.medium

                DetailsPanel {
                    id: detailsPanel
                    visible: root.detailsShown
                    Layout.fillWidth: true
                    isGroup: root.selectedIsGroup
                    description: root.selectedDescription
                    conversationId: root.selectedConversationId
                    peerAddress: store.currentPeerAddress
                    memberCount: store.memberCount
                    pendingMemberCount: store.pendingMemberCount
                    onCloseRequested: root.detailsShown = false
                }

                MembersPane {
                    visible: root.selectedIsGroup
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    memberModel: store.memberModel
                    memberCount: store.memberCount
                    online: store.online
                    ready: root.selectionLoaded
                    onAddMemberRequested: addMemberDialog.open()
                }
            }
        }

        StatusBar {
            Layout.fillWidth: true
            errorMessage: root.lastError
            errorCount: root.unseenErrorCount
            onErrorActivated: root.showLogs()
            onLogsRequested: root.showLogs()
        }
    }

    // Opening the logs is what marks the held failures seen: the strip goes
    // quiet, and nothing is discarded — the list is behind the button.
    function showLogs() {
        // The files rotate and get pruned while the app runs, so the list is
        // read at the moment it is shown.
        store.refreshLogRuns();
        root.lastError = "";
        root.unseenErrorCount = 0;
        sessionLogsDialog.open();
    }

    SessionLogsDialog {
        id: sessionLogsDialog
        errors: store.errors
        runs: store.logRuns
        logDir: store.logDir
    }

    // What you want to do, then who with, then which account — the order the
    // app is arguing for, rather than "one person or a group?".
    NewActivityDialog {
        id: newActivityDialog
        walletReady: store.walletReady
        privateBalance: store.privateBalance
        onActivityChosen: function (verb, peerAddress) {
            store.startActivity(verb, peerAddress);
        }
    }

    NewConversationDialog {
        id: newConvDialog
        onAddressEntered: function (address) {
            store.createConversation(address);
        }
    }

    NewGroupDialog {
        id: newGroupDialog
        onGroupDetailsEntered: function (name, description) {
            store.createGroup(name, description);
        }
    }

    // Opened by a "Send LEZ" action on an address-share card; the recipient is
    // carried from that card, so this only ever asks for an amount.
    SendDialog {
        id: sendDialog
        onConfirmed: function (amount) {
            store.sendPrivate(sendDialog.keysJson, amount);
        }
    }

    AddMemberDialog {
        id: addMemberDialog
        onAddressEntered: function (address) {
            // First member add: explain the async commit delay first, then invite.
            if (chatPrefs.memberAddExplained) {
                store.addMember(address);
            } else {
                memberAddInfoDialog.pendingAddress = address;
                memberAddInfoDialog.open();
            }
        }
    }

    MemberAddInfoDialog {
        id: memberAddInfoDialog
        // The address whose add opened the explainer, applied once confirmed.
        property string pendingAddress: ""
        onConfirmed: function (dontShowAgain) {
            if (dontShowAgain)
                chatPrefs.memberAddExplained = true;
            if (pendingAddress !== "")
                store.addMember(pendingAddress);
            pendingAddress = "";
        }
    }

    // Persisted UI preferences.
    Settings {
        id: chatPrefs
        category: "chat_ui"
        property bool memberAddExplained: false
    }
}
