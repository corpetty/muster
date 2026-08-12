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
                    // Same reason as the strip below: a list of holdings is
                    // taller than the two numbers this replaced, and a squeezed
                    // wallet clips the row that says why a holding is unusable.
                    Layout.minimumHeight: implicitHeight
                    ready: store.walletReady
                    busy: store.walletBusy
                    stage: store.walletStage
                    statusLabel: store.walletLabel
                    assets: store.assets
                    receivedElsewhere: store.receivedElsewhere
                    errorText: store.walletError
                    onOpenRequested: store.openWallet()
                    onFundRequested: store.fundWallet()
                    onRefreshRequested: store.refreshBalances()
                    // Empty amount means all of it, which is what the card's
                    // one-tap claim asks for.
                    onClaimRequested: function (assetId) {
                        store.claimHolding(assetId, "");
                    }
                }

                // Under the wallet, so the running job sits with the thing it
                // is doing — and stays visible while the user carries on with
                // the conversation, which is the point of it being a job.
                //
                // The minimum height is load-bearing, not tidying. The wallet
                // card above grew from two numbers to a list of holdings with
                // notes, and in a sidebar this tall that is enough to squeeze
                // the strip to nothing — silently, and worst at exactly the
                // moment it matters, because the strip only has content while
                // a job is running. A seven-minute proof with no strip is
                // indistinguishable from a hang. ActionsPane fills the slack,
                // so it is the one that should give the space up.
                JobStrip {
                    objectName: "jobStrip"
                    Layout.fillWidth: true
                    Layout.minimumHeight: implicitHeight
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
                // More than one answer to "where do I pay you", and the choice
                // is the payee's — sharing a public account invites a payment
                // anyone can read. One receivable holding still asks, because
                // the dialog is where that trade-off is stated.
                onShareAddressRequested: shareAddressDialog.open()
                onPayRequested: function (toAddress, addressForm, assetName, label) {
                    sendDialog.toAddress = toAddress;
                    sendDialog.addressForm = addressForm;
                    sendDialog.assetName = assetName;
                    sendDialog.assetKnown = store.railsPaying(addressForm).length > 0;
                    sendDialog.peerLabel = label;
                    // Only the rails that can pay this form of address. The
                    // dialog is handed the answer rather than the catalogue, so
                    // it never has to know what a rail is.
                    sendDialog.rails = store.railsPaying(addressForm);
                    sendDialog.open();
                }
                intents: store.intents
                liveIntent: store.liveIntent
                onProposeRequested: function (toAddress, addressForm, assetName, label) {
                    proposeDialog.toAddress = toAddress;
                    proposeDialog.addressForm = addressForm;
                    proposeDialog.assetName = assetName;
                    proposeDialog.assetKnown = store.railsPaying(addressForm).length > 0;
                    proposeDialog.peerLabel = label;
                    proposeDialog.rails = store.railsPaying(addressForm);
                    proposeDialog.memberCount = store.memberCount;
                    proposeDialog.open();
                }
                onApproveRequested: function (intentId) {
                    store.approveIntent(intentId);
                }
                onDropRequested: function (intentId) {
                    store.dropIntent(intentId, "");
                }
                onSubmitRequested: function (intentId) {
                    store.submitIntent(intentId);
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
        assets: store.assets
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

    // Answering "where do I pay you". The payee chooses which of their holdings
    // to advertise, because that choice decides what a payment to them can
    // hide — see ShareAddressDialog.
    ShareAddressDialog {
        id: shareAddressDialog
        assets: store.receivableAssets
        onConfirmed: function (assetId) {
            store.shareAddress(assetId);
        }
    }

    // Opened by the "Send" action on an address-share card; the recipient is
    // carried from that card, so this only asks for an amount and a rail.
    SendDialog {
        id: sendDialog
        onConfirmed: function (railId, amount) {
            store.sendPayment(railId, sendDialog.toAddress, amount);
        }
    }

    // The same card's other action: put the payment to the room first. Asks
    // for an amount, a rail, and how many people must agree before it can be
    // paid.
    ProposeDialog {
        id: proposeDialog
        onConfirmed: function (railId, amount, threshold) {
            store.proposePayment(railId, proposeDialog.toAddress, proposeDialog.peerLabel,
                                 amount, threshold);
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
