pragma ComponentBehavior: Bound

import QtQuick
import QtTest

import ChatUi

// Standalone-instantiability + behaviour tests for the ChatUi components. Run
// headless with qmltestrunner, giving it src/qml on the import path (so `import
// ChatUi` resolves) and the design system's lib dir (so Logos.* resolves):
//   qmltestrunner -input tests/qml -import src/qml -import <app>/lib -platform offscreen
// Every component must instantiate with mock data and no host `logos` context —
// that is the house-rule-2 proof; a broken import or a misused Logos API surfaces
// here as a null object.
Item {
    id: testRoot
    width: 400
    height: 400

    // ── mock data ────────────────────────────────────────────────────────
    ListModel {
        id: conversationsMock
        ListElement {
            conversationId: "c1"
            displayName: "Alice"
            isGroup: false
            avatarInitials: "c1"
            avatarRamp: 0
            unreadCount: 0
            lastActivityDisplay: "12:34"
            preview: "See you tomorrow"
            description: ""
        }
        ListElement {
            conversationId: "c2"
            displayName: "Team"
            isGroup: true
            avatarInitials: "c2"
            avatarRamp: 3
            unreadCount: 42
            lastActivityDisplay: "12:34"
            preview: "Alice: shipping the new theme"
            description: "Shipping the new theme"
        }
    }
    ListModel {
        id: messagesMock
        ListElement {
            sender: "Alice"
            avatarInitials: "al"
            avatarRamp: 0
            content: "Hi there"
            timeDisplay: "12:34"
            isMe: false
            sameSenderAsPrevious: false
            showDaySeparator: true
            dayLabel: "Today"
        }
    }
    ListModel {
        id: emptyMessagesMock
    }
    ListModel {
        id: emptyMembersMock
    }
    ListModel {
        id: membersMock
        ListElement {
            address: "0xabc"
            label: "Alice"
            avatarInitials: "0x"
            avatarRamp: 1
            isSelf: false
            pending: false
        }
    }

    // ── components under test ────────────────────────────────────────────
    Component {
        id: conversationsPaneC
        ConversationsPane {
            conversationModel: conversationsMock
            currentConversationId: "c1"
            online: true
        }
    }
    Component {
        id: messageThreadPaneC
        MessageThreadPane {
            messageModel: messagesMock
            currentIsGroup: false
            title: "Alice"
            conversationId: "c1"
            hasConversation: true
            online: true
            ready: true
        }
    }
    Component {
        id: emptyMembersPaneC
        MembersPane {
            memberModel: emptyMembersMock
            online: true
            ready: true
        }
    }
    Component {
        id: emptyThreadPaneC
        MessageThreadPane {
            messageModel: emptyMessagesMock
            currentIsGroup: false
            title: "Alice"
            conversationId: "c1"
            hasConversation: true
            online: true
            ready: true
        }
    }
    Component {
        id: membersPaneC
        MembersPane {
            memberModel: membersMock
            online: true
            ready: true
        }
    }
    Component {
        id: accountCardC
        AccountCard {
            address: "0xdeadbeef0123456789abcdef"
            label: "0xdeadbe"
            initials: "0x"
            online: true
            statusLabel: "Online"
        }
    }
    Component {
        id: avatarC
        Avatar {
            initials: "0x"
            ramp: 1
        }
    }
    Component {
        id: chatIconButtonC
        ChatIconButton {
            iconSource: Qt.resolvedUrl("../../src/qml/ChatUi/icons/copy.png")
        }
    }
    Component {
        id: chatMenuItemC
        ChatMenuItem {
            text: "Direct message"
            description: "One person, by address"
        }
    }
    Component {
        id: dayChipC
        DayChip {
            text: "Today"
        }
    }
    Component {
        id: facepileC
        Facepile {
            memberModel: membersMock
            memberCount: 5
        }
    }
    Component {
        id: panelHeaderC
        PanelHeader {
            title: "Members"
            count: 3
        }
    }
    Component {
        id: detailRowC
        DetailRow {
            key: "Conversation"
            value: "0xconversationid"
            mono: true
            copyable: true
        }
    }
    Component {
        id: threadHeaderC
        ThreadHeader {
            title: "Design Team"
            description: "A description long enough that the header has to elide it rather than wrap"
            isGroup: true
            avatarInitials: "c2"
            avatarRamp: 3
            memberModel: membersMock
            memberCount: 3
        }
    }
    Component {
        id: emptyStateC
        EmptyState {
            text: "Nothing here"
        }
    }
    Component {
        id: messageComposerC
        MessageComposer {
            placeholder: "Type a message..."
            submitEnabled: true
        }
    }
    Component {
        id: statusBarC
        StatusBar {
            width: 360
            errorMessage: ""
            errorCount: 0
        }
    }
    Component {
        id: clipboardProxyC
        ClipboardProxy {}
    }
    Component {
        id: sessionLogsDialogC
        SessionLogsDialog {
            logDir: "/data/module_data/chat_module/74fe12d2b288"
            // Two writers in one directory, which is what the tabs divide, plus
            // one run of this view's that rotated.
            runs: [
                {
                    writer: "chat_ui",
                    label: "2026-07-28 10:00:00",
                    sizeLabel: "96 KB",
                    fileCount: 1,
                    path: "/data/module_data/chat_module/74fe12d2b288/chat_ui_20260728_100000.log",
                    paths: "/data/module_data/chat_module/74fe12d2b288/chat_ui_20260728_100000.log",
                    stamp: "20260728_100000",
                    current: true
                },
                {
                    writer: "chat_module",
                    label: "2026-07-28 10:00:00",
                    sizeLabel: "1.2 MB",
                    fileCount: 2,
                    path: "/data/module_data/chat_module/74fe12d2b288/chat_module_20260728_100000.log",
                    paths: "/data/module_data/chat_module/74fe12d2b288/chat_module_20260728_100000.001.log\n/data/module_data/chat_module/74fe12d2b288/chat_module_20260728_100000.log",
                    stamp: "20260728_100000",
                    current: true
                },
                {
                    writer: "chat_module",
                    label: "2026-07-27 09:00:00",
                    sizeLabel: "300 KB",
                    fileCount: 1,
                    path: "/data/module_data/chat_module/74fe12d2b288/chat_module_20260727_090000.log",
                    paths: "/data/module_data/chat_module/74fe12d2b288/chat_module_20260727_090000.log",
                    stamp: "20260727_090000",
                    current: false
                }
            ]
            errors: [
                {
                    when: "14:32:07",
                    message: "Failed to add member: no key package for peer",
                    count: 1
                },
                {
                    when: "14:29:02",
                    message: "Delivery error: connection refused",
                    count: 3
                }
            ]
        }
    }
    // The same dialog with nothing to report, for the tab it opens on.
    Component {
        id: quietLogsDialogC
        SessionLogsDialog {
            logDir: "/data/module_data/chat_module/74fe12d2b288"
            runs: []
            errors: []
        }
    }
    Component {
        id: newConvDialogC
        NewConversationDialog {}
    }
    Component {
        id: newGroupDialogC
        NewGroupDialog {}
    }
    Component {
        id: memberAddInfoDialogC
        MemberAddInfoDialog {}
    }
    Component {
        id: addMemberDialogC
        AddMemberDialog {}
    }
    Component {
        id: detailsPanelC
        DetailsPanel {
            isGroup: true
            description: "Design reviews and theme work"
            conversationId: "0xconversationid"
            memberCount: 3
        }
    }
    Component {
        id: conversationDelegateC
        ConversationDelegate {
            conversationId: "c1"
            displayName: "Alice"
            isGroup: true
            avatarInitials: "c1"
            avatarRamp: 2
            unreadCount: 3
            lastActivityDisplay: "12:34"
            preview: "See you tomorrow"
            description: "Ship it"
            currentConversationId: "c1"
        }
    }
    Component {
        id: messageDelegateC
        MessageDelegate {
            content: "<b>not bold</b>"
            isMe: false
            timeDisplay: "12:34"
            sender: "Alice"
            avatarInitials: "al"
            avatarRamp: 2
            groupContext: true
            sameSenderAsPrevious: false
            showDaySeparator: true
            dayLabel: "Today"
        }
    }
    Component {
        id: messageSkeletonC
        MessageSkeleton {}
    }
    Component {
        id: memberDelegateC
        MemberDelegate {
            label: "Carol"
            address: "0xcarol"
            avatarInitials: "0x"
            avatarRamp: 4
            isSelf: false
            pending: true
        }
    }

    SignalSpy {
        id: submitSpy
        signalName: "submitted"
    }
    SignalSpy {
        id: addressSpy
        signalName: "addressEntered"
    }
    SignalSpy {
        id: confirmedSpy
        signalName: "confirmed"
    }
    SignalSpy {
        id: groupDetailsSpy
        signalName: "groupDetailsEntered"
    }
    SignalSpy {
        id: detailsSpy
        signalName: "detailsRequested"
    }
    SignalSpy {
        id: addMemberReqSpy
        signalName: "addMemberRequested"
    }
    SignalSpy {
        id: conversationSelectedSpy
        signalName: "conversationSelected"
    }
    SignalSpy {
        id: newConversationSpy
        signalName: "newConversationRequested"
    }
    SignalSpy {
        id: newGroupSpy
        signalName: "newGroupRequested"
    }
    SignalSpy {
        id: copyDetailSpy
        signalName: "copyRequested"
    }
    SignalSpy {
        id: detailsToggledSpy
        signalName: "detailsToggled"
    }
    SignalSpy {
        id: contextMenuRequestedSpy
        signalName: "contextMenuRequested"
    }
    SignalSpy {
        id: contextMenuSpy
        signalName: "contextMenuRequested"
    }
    SignalSpy {
        id: errorActivatedSpy
        signalName: "errorActivated"
    }
    SignalSpy {
        id: logsRequestedSpy
        signalName: "logsRequested"
    }

    TestCase {
        name: "ChatUiComponents"
        when: windowShown

        function instantiate(comp) {
            const obj = createTemporaryObject(comp, this);
            verify(obj, "component failed to instantiate standalone");
            return obj;
        }

        // Find a named field anywhere under an item, descending the visual
        // children, a Control/ScrollView contentItem, and the non-visual data, so
        // a field inside a LogosScrollView or an entry inside a menu popup is
        // still reachable.
        function findField(obj, objectName) {
            if (!obj)
                return null;
            if (obj.objectName === objectName)
                return obj;
            const pools = [obj.children, obj.contentItem ? [obj.contentItem] : [], obj.contentData || [], obj.data || []];
            for (let p = 0; p < pools.length; ++p) {
                const pool = pools[p];
                for (let i = 0; pool && i < pool.length; ++i) {
                    const found = findField(pool[i], objectName);
                    if (found)
                        return found;
                }
            }
            return null;
        }

        // Every named field under an item, for the repeated rows a list draws.
        function collectFields(obj, objectName, found) {
            if (!obj)
                return found;
            // `data` repeats `children`, so a row is reachable twice.
            if (obj.objectName === objectName && found.indexOf(obj) === -1)
                found.push(obj);
            const pools = [obj.children, obj.contentItem ? [obj.contentItem] : [], obj.contentData || [], obj.data || []];
            for (let p = 0; p < pools.length; ++p) {
                const pool = pools[p];
                for (let i = 0; pool && i < pool.length; ++i)
                    collectFields(pool[i], objectName, found);
            }
            return found;
        }

        function test_panesInstantiate() {
            instantiate(conversationsPaneC);
            instantiate(messageThreadPaneC);
            instantiate(membersPaneC);
            instantiate(accountCardC);
        }

        function test_leafComponentsInstantiate() {
            instantiate(avatarC);
            instantiate(detailsPanelC);
            instantiate(chatIconButtonC);
            instantiate(dayChipC);
            instantiate(facepileC);
            instantiate(panelHeaderC);
            instantiate(detailRowC);
            instantiate(threadHeaderC);
            instantiate(messageSkeletonC);
            instantiate(emptyStateC);
            instantiate(statusBarC);
            instantiate(clipboardProxyC);
        }

        // copy() writes without throwing; an empty string is a no-op.
        function test_clipboardProxyCopies() {
            const clip = instantiate(clipboardProxyC);
            clip.copy("");
            clip.copy("0xdeadbeef");
        }

        function test_dialogsInstantiate() {
            instantiate(newConvDialogC);
            instantiate(newGroupDialogC);
            instantiate(memberAddInfoDialogC);
        }

        // A direct conversation's details name the peer once their address is
        // known, and carry the conversation id either way.
        function test_detailsPanelAddressRow() {
            const panel = createTemporaryObject(detailsPanelC, testRoot);
            verify(panel, "the details panel must instantiate");
            const addressRow = findField(panel, "peerAddressRow");
            const idRow = findField(panel, "conversationIdRow");
            verify(addressRow && idRow, "both rows must be reachable");
            verify(idRow.visible, "the conversation id shows for a group");
            verify(!addressRow.visible, "a group has no single peer to name");

            panel.isGroup = false;
            verify(!addressRow.visible, "no address row while the peer is unknown");
            panel.peerAddress = "0xpeer";
            verify(addressRow.visible, "the address row appears once known");
        }

        // Details is offered for every conversation, a direct one included, and
        // requests the panel. Parented into the shown root and sized so
        // effective visibility is meaningful.
        function test_threadPaneDetailsButton() {
            const pane = createTemporaryObject(messageThreadPaneC, testRoot);
            verify(pane, "the thread pane must instantiate");
            pane.width = 400;
            pane.height = 300;
            const details = findField(pane, "detailsButton");
            verify(details, "the details button must be reachable");
            verify(details.visible, "Details shows for a direct conversation");

            pane.currentIsGroup = true;
            verify(details.visible, "Details shows for a group too");

            detailsSpy.target = pane;
            detailsSpy.clear();
            details.clicked();
            compare(detailsSpy.count, 1, "clicking Details asks for the details");
        }

        // A conversation whose messages have not arrived yet shows neither the
        // rows left behind by the previous one nor a premature empty state; the
        // skeleton waits out the grace interval, and the row count keeps
        // reporting the model.
        function test_threadPaneGatesUnloadedConversation() {
            const pane = createTemporaryObject(messageThreadPaneC, testRoot);
            verify(pane, "the thread pane must instantiate");
            pane.width = 400;
            pane.height = 300;
            const list = findField(pane, "threadList");
            const skeleton = findField(pane, "threadSkeleton");
            const empty = findField(pane, "threadEmptyState");
            verify(list && skeleton && empty, "the thread parts must be reachable");
            verify(list.visible, "a loaded thread shows its rows");
            verify(!skeleton.visible, "a loaded thread shows no skeleton");

            pane.conversationId = "c2";
            pane.ready = false;
            verify(!pane.threadReady, "a conversation still loading is not ready");
            verify(!list.visible, "rows of the previous conversation stay hidden");
            verify(!empty.visible, "no empty state while the thread is loading");
            verify(!skeleton.visible, "no skeleton within the grace interval");
            compare(pane.messageCount, 1, "the row count still reports the model");
            tryCompare(skeleton, "visible", true, 3000, "a longer wait shows the skeleton");

            pane.ready = true;
            verify(list.visible, "the thread shows once its messages are loaded");
            verify(!skeleton.visible, "the skeleton goes with the wait");

            // A refetch under the same conversation is a wait like any other.
            pane.ready = false;
            verify(!skeleton.visible, "a reload gets the grace interval too");
            tryCompare(skeleton, "visible", true, 3000, "and the skeleton after it");
        }

        // An actually empty thread says so, but only after the model has had a
        // moment to fill: the messages arrive on their own replica, a beat after
        // the conversation counts as loaded.
        function test_threadPaneEmptyStateSettles() {
            const pane = createTemporaryObject(emptyThreadPaneC, testRoot);
            verify(pane, "the thread pane must instantiate");
            pane.width = 400;
            pane.height = 300;
            const empty = findField(pane, "threadEmptyState");
            verify(empty, "the empty state must be reachable");

            pane.conversationId = "c2";
            verify(!empty.visible, "an empty model right after a switch says nothing");
            tryCompare(empty, "visible", true, 3000, "a thread that stays empty says so");
        }

        // A roster that has just loaded does not claim to be empty until the
        // model has had a moment to fill, for the same reason the thread waits.
        function test_membersPaneEmptyStateSettles() {
            const pane = createTemporaryObject(emptyMembersPaneC, testRoot);
            verify(pane, "the members pane must instantiate");
            pane.width = 220;
            pane.height = 300;
            const empty = findField(pane, "memberEmptyState");
            verify(empty, "the empty state must be reachable");

            pane.ready = false;
            pane.ready = true;
            verify(!empty.visible, "an empty model right after a switch says nothing");
            tryCompare(empty, "visible", true, 3000, "a roster that stays empty says so");
        }

        // The roster is gated the same way: a switch never shows the previous
        // conversation's members, nor claims the new one has none.
        function test_membersPaneGatesUnloadedRoster() {
            const pane = createTemporaryObject(membersPaneC, testRoot);
            verify(pane, "the members pane must instantiate");
            pane.width = 220;
            pane.height = 300;
            const list = findField(pane, "memberList");
            const empty = findField(pane, "memberEmptyState");
            verify(list && empty, "the roster parts must be reachable");
            verify(list.visible, "a loaded roster shows its rows");

            pane.ready = false;
            verify(!list.visible, "rows of the previous conversation stay hidden");
            verify(!empty.visible, "no empty state while the roster is loading");
        }

        // Selecting a row carries the row's own data, which is what lets a view
        // render the selection before the backend has switched to it.
        function test_conversationsPaneSelectionCarriesTheRow() {
            const pane = createTemporaryObject(conversationsPaneC, testRoot);
            verify(pane, "the sidebar must instantiate");
            pane.width = 260;
            pane.height = 400;

            conversationSelectedSpy.target = pane;
            conversationSelectedSpy.clear();

            const list = findField(pane, "conversationList");
            verify(list, "the conversation list must be reachable");
            tryVerify(() => list.itemAtIndex(1) !== null, 2000, "the second row must be realised");
            list.itemAtIndex(1).clicked();

            compare(conversationSelectedSpy.count, 1, "clicking a row selects it once");
            const conversation = conversationSelectedSpy.signalArguments[0][0];
            compare(conversation.conversationId, "c2", "the conversation id");
            compare(conversation.displayName, "Team", "its display name");
            compare(conversation.isGroup, true, "whether it is a group");
            compare(conversation.description, "Shipping the new theme", "its description");
            compare(conversation.avatarInitials, "c2", "and the avatar identity the header needs");
            compare(conversation.avatarRamp, 3, "with its colour");
        }

        // A closed composer names why it is closed, so a connected app with
        // nothing selected does not claim to be offline.
        function test_threadPaneDisabledPlaceholder() {
            const pane = createTemporaryObject(messageThreadPaneC, testRoot);
            verify(pane, "the thread pane must instantiate");
            const composer = findField(pane, "composer");
            verify(composer, "the composer must be reachable");

            pane.hasConversation = false;
            compare(composer.disabledPlaceholder, "Select a conversation to start chatting", "online with nothing selected");

            pane.online = false;
            compare(composer.disabledPlaceholder, "Chat not connected", "offline");
        }

        // A refused message comes back to the composer, and a composer the user
        // has already typed into is left alone.
        function test_threadPaneRestoresFailedSend() {
            const pane = createTemporaryObject(messageThreadPaneC, testRoot);
            verify(pane, "the thread pane must instantiate");
            const composer = findField(pane, "composer");
            verify(composer, "the composer must be reachable");

            pane.restoreFailedSend("c1", "lost message");
            compare(composer.text, "lost message", "the refused text comes back");

            composer.text = "already typing";
            pane.restoreFailedSend("c1", "lost message");
            compare(composer.text, "already typing", "a composer in use is left alone");

            composer.text = "";
            pane.restoreFailedSend("other", "not mine");
            compare(composer.text, "", "a refusal from another conversation stays out");
        }

        // One identity, one colour: the ramp a model hands out has to land
        // inside the table the avatar draws from.
        function test_avatarRampsCoverEveryIndex() {
            compare(ChatTheme.avatarRamps.length, 5, "the ramp table matches Identity::kAvatarRampCount");
            const avatar = createTemporaryObject(avatarC, testRoot);
            verify(avatar, "the avatar must instantiate");
            for (let ramp = 0; ramp < ChatTheme.avatarRamps.length; ++ramp) {
                avatar.ramp = ramp;
                verify(avatar.gradient, "ramp %1 must resolve to a gradient".arg(ramp));
            }
        }

        // A pile can only show so many faces, so the rest become a count
        // rather than an ever-narrower row of tiles.
        function test_facepileCountsWhoDoesNotFit() {
            const pile = createTemporaryObject(facepileC, testRoot);
            verify(pile, "the facepile must instantiate");
            compare(pile.overflow, 2, "two of the five members are over the limit");

            pile.memberCount = 3;
            compare(pile.overflow, 0, "a roster that fits leaves no remainder");
        }

        // The heading counts what the card holds, and says nothing where there
        // is nothing to count.
        function test_panelHeaderCount() {
            const header = createTemporaryObject(panelHeaderC, testRoot);
            verify(header, "the panel header must instantiate");
            const pill = findField(header, "panelCount");
            verify(pill, "the count pill must be reachable");
            verify(pill.visible, "a card with rows says how many");

            header.count = -1;
            verify(!pill.visible, "a card with nothing to count says nothing");
        }

        // A detail row's copy carries the value beside it, not the row's key.
        function test_detailRowCopiesItsValue() {
            const row = createTemporaryObject(detailRowC, testRoot);
            verify(row, "the detail row must instantiate");
            const btn = findField(row, "copyDetailButton");
            verify(btn, "the copy button must be reachable");
            verify(btn.visible, "a copyable row offers it");

            copyDetailSpy.target = row;
            copyDetailSpy.clear();
            btn.clicked();
            compare(copyDetailSpy.count, 1, "the button requests the copy");
            compare(copyDetailSpy.signalArguments[0][0], "0xconversationid", "with the row's value");

            row.copyable = false;
            verify(!btn.visible, "a row with nothing to take offers no copy");
        }

        // The header keeps a long description to one line, whatever its length,
        // so the thread below it never loses room.
        function test_threadHeaderClampsItsDescription() {
            const header = createTemporaryObject(threadHeaderC, testRoot);
            verify(header, "the thread header must instantiate");
            header.width = 400;
            const description = findField(header, "threadDescription");
            verify(description, "the description must be reachable");
            tryVerify(() => description.truncated, 2000, "a long description elides");
            compare(header.implicitHeight, 76, "and the header stays its own height");

            detailsToggledSpy.target = header;
            detailsToggledSpy.clear();
            findField(header, "detailsButton").clicked();
            compare(detailsToggledSpy.count, 1, "the toggle asks for the details");
        }

        // A group is a place, not a person, so it carries a glyph and the
        // squarer tile rather than someone's initials.
        function test_avatarMarksAGroup() {
            const avatar = createTemporaryObject(avatarC, testRoot);
            verify(avatar, "the avatar must instantiate");
            compare(avatar.radius, avatar.size / 2, "a person is round");

            avatar.isGroup = true;
            compare(avatar.radius, Math.round(avatar.size * 0.34), "a group is squared off");
        }

        // The address is what a peer needs, so the card shows it in full and
        // confirms the copy where the value is.
        function test_accountCardCopiesTheAddress() {
            const card = instantiate(accountCardC);
            const btn = findField(card, "copyMyAddressButton");
            verify(btn, "the copy button must be reachable");

            const address = findField(card, "myAddressText");
            verify(address, "the address must be reachable");
            compare(address.text, card.address, "the field carries the address");

            btn.clicked();
            verify(card.copiedFlashing, "the copy is confirmed");
            compare(address.text, "Copied to clipboard", "and the confirmation lands on the value");
        }

        // Before the network is up there is no address to show, and a card
        // showing an empty field would read as a failure rather than a wait.
        function test_accountCardHidesAnUnknownAddress() {
            const card = createTemporaryObject(accountCardC, testRoot);
            verify(card, "the card must instantiate");
            const label = findField(card, "myLabelText");
            const address = findField(card, "myAddressText");
            verify(label && address, "the identity and the address must be reachable");
            verify(label.visible && address.visible, "a known account shows both");

            card.address = "";
            card.label = "";
            verify(!label.visible, "an unknown identity leaves no empty line");
            tryVerify(() => !address.visible, 2000, "and no empty address field");
        }

        // The roster line counts who is in and names invitations that have not
        // landed yet, since an invited member is not one until they join.
        function test_detailsPanelMemberSummary() {
            const panel = instantiate(detailsPanelC);
            panel.memberCount = 1;
            panel.pendingMemberCount = 0;
            compare(panel.memberSummary, "1 joined", "a single member");
            panel.memberCount = 3;
            compare(panel.memberSummary, "3 joined", "several members");
            panel.pendingMemberCount = 1;
            compare(panel.memberSummary, "3 joined, 1 invited", "an outstanding invitation");
            panel.pendingMemberCount = 2;
            compare(panel.memberSummary, "3 joined, 2 invited", "several outstanding invitations");
        }

        // The header's New menu offers both kinds of conversation, and picking
        // one requests it.
        function test_conversationsPaneNewMenu() {
            const pane = createTemporaryObject(conversationsPaneC, testRoot);
            verify(pane, "the sidebar must instantiate");
            pane.width = 260;
            pane.height = 400;

            const button = findField(pane, "newMenuButton");
            verify(button, "the New button must be reachable");
            const menu = findField(pane, "newMenu");
            verify(menu && !menu.opened, "the menu starts closed");
            button.clicked();
            tryVerify(() => menu.opened, 2000, "clicking New opens the menu");
            menu.close();

            const dm = findField(pane, "newDmMenuItem");
            const group = findField(pane, "newGroupMenuItem");
            verify(dm && group, "both menu entries must be reachable");

            newConversationSpy.target = pane;
            newConversationSpy.clear();
            newGroupSpy.target = pane;
            newGroupSpy.clear();

            dm.triggered();
            compare(newConversationSpy.count, 1, "the DM entry requests a direct message");
            group.triggered();
            compare(newGroupSpy.count, 1, "the group entry requests a group");
        }

        // A roster row offers a copy button, hidden until the row is hovered so a
        // resting roster stays clean; using it flashes the same confirmation a
        // row click does.
        // The roster rests clean: a row is nothing but identity, and its actions
        // come from a right-click that carries the address they act on.
        function test_memberDelegateOffersItsActions() {
            const pane = createTemporaryObject(membersPaneC, testRoot);
            verify(pane, "the members pane must instantiate");
            pane.width = 280;
            pane.height = 300;
            const menu = findField(pane, "memberMenu");
            const copy = findField(pane, "copyMemberAddressMenuItem");
            verify(menu && copy, "the roster menu and its copy entry must be reachable");

            const list = findField(pane, "memberList");
            tryVerify(() => list.itemAtIndex(0) !== null, 2000, "the first row must be realised");
            const row = list.itemAtIndex(0);
            contextMenuRequestedSpy.target = row;
            contextMenuRequestedSpy.clear();
            row.contextMenuRequested(row.address);
            compare(contextMenuRequestedSpy.count, 1, "a row asks for its actions");
            compare(contextMenuRequestedSpy.signalArguments[0][0], "0xabc", "carrying its own address");

            menu.row = row;
            copy.triggered();
            verify(row.copiedFlashing, "the copy confirms on the row it came from");
        }

        // A right-click asks for the message actions, offering the selection
        // when the user made one and the whole message otherwise.
        function test_messageDelegateContextMenu() {
            const bubble = createTemporaryObject(messageDelegateC, testRoot);
            verify(bubble, "the bubble must instantiate");
            bubble.width = 300;
            const body = findField(bubble, "messageText");
            const box = findField(bubble, "bubble");
            verify(body && box, "the message text and its background must be reachable");

            compare(bubble.copyText, "<b>not bold</b>", "a message with no selection copies whole");
            body.select(0, 3);
            compare(bubble.copyText, "<b>", "a selection copies just that");
            body.deselect();

            contextMenuSpy.target = bubble;
            contextMenuSpy.clear();
            mouseClick(box, box.width / 2, box.height / 2, Qt.RightButton);
            compare(contextMenuSpy.count, 1, "a right-click asks for the menu");
            compare(contextMenuSpy.signalArguments[0][0], "<b>not bold</b>", "carrying what to copy");
        }

        // A row's right-click hands the thread's shared menu that row's text.
        function test_threadPaneMessageMenu() {
            const pane = createTemporaryObject(messageThreadPaneC, testRoot);
            verify(pane, "the thread pane must instantiate");
            pane.width = 400;
            pane.height = 300;
            const entry = findField(pane, "copyMessageMenuItem");
            const menu = findField(pane, "messageMenu");
            const list = findField(pane, "threadList");
            verify(entry && menu && list, "the menu, its copy entry and the thread must be reachable");
            compare(menu.copyText, "", "nothing to copy before a row asks");

            tryVerify(() => list.itemAtIndex(0) !== null, 2000, "the message row must be realised");
            list.itemAtIndex(0).contextMenuRequested("Hi there");
            compare(menu.copyText, "Hi there", "the row hands the menu its text");
            entry.triggered();
        }

        // A conversation nobody has written in yet says so, rather than leaving
        // the row's second line blank.
        function test_conversationDelegatePreviewPlaceholder() {
            const del = instantiate(conversationDelegateC);
            const preview = findField(del, "previewLabel");
            verify(preview, "the preview line must be reachable");
            compare(preview.text, "See you tomorrow", "a conversation with messages previews the last one");

            del.preview = "";
            compare(preview.text, "No messages yet", "an untouched conversation says so");
        }

        function test_delegatesInstantiate() {
            instantiate(conversationDelegateC);
            instantiate(messageDelegateC);
            instantiate(memberDelegateC);
        }

        // The sender label shows on the first message of a run in a group, is
        // suppressed on continuations, and never shows on own messages.
        function test_messageDelegateGrouping() {
            const bubble = instantiate(messageDelegateC);
            verify(bubble.showSender, "first message of a run in a group shows the sender");
            bubble.sameSenderAsPrevious = true;
            verify(!bubble.showSender, "a continuation hides the sender label");
            bubble.sameSenderAsPrevious = false;
            bubble.isMe = true;
            verify(!bubble.showSender, "own messages never show a sender label");
        }

        // The body is read-only selectable text, and a selection yields the raw
        // string, so markup in a message stays literal.
        function test_messageDelegateTextSelectable() {
            const bubble = instantiate(messageDelegateC);
            const body = findField(bubble, "messageText");
            verify(body, "the message text must be reachable");
            verify(body.readOnly, "the body must not be editable");
            verify(body.selectByMouse, "the body must be selectable with the mouse");

            body.selectAll();
            compare(body.selectedText, "<b>not bold</b>", "the selection is the literal plain text");
        }

        // The bubble hugs a short message and caps a long one at 70% of the row.
        // Guards the sizing formula, which reads the body's implicit size.
        function test_messageDelegateSizing() {
            const shortBubble = createTemporaryObject(messageDelegateC, testRoot);
            const longBubble = createTemporaryObject(messageDelegateC, testRoot);
            verify(shortBubble && longBubble, "both bubbles must instantiate");
            shortBubble.width = 400;
            shortBubble.content = "Hi";
            longBubble.width = 400;
            longBubble.content = "A message long enough to need wrapping. ".repeat(10);

            const shortBox = findField(shortBubble, "bubble");
            const longBox = findField(longBubble, "bubble");
            verify(shortBox && longBox, "both bubble backgrounds must be reachable");
            verify(shortBox.width > 0, "a short bubble must still have a width");
            verify(shortBox.width < longBox.width, "a short message makes a narrower bubble");
            compare(longBox.width, 280, "a long message caps at 70% of the row");
            verify(longBox.height > shortBox.height, "wrapped content makes a taller bubble");
        }

        // The current conversation highlights; a different one does not.
        function test_conversationDelegateHighlight() {
            const del = instantiate(conversationDelegateC);
            verify(del.highlighted, "the current conversation should be highlighted");
            del.currentConversationId = "other";
            verify(!del.highlighted, "a non-current conversation should not be highlighted");
        }

        // The composer trims, emits, and clears; a blank entry and a gated-off
        // composer are both no-ops. The Enter/Shift+Enter handling is declarative
        // in the field's key handlers and not key-simulated here.
        function test_messageComposerSubmits() {
            const composer = instantiate(messageComposerC);
            const send = findField(composer, "sendButton");
            verify(send, "the send button must be reachable");
            submitSpy.target = composer;
            submitSpy.clear();

            composer.text = "   ";
            send.clicked();
            compare(submitSpy.count, 0, "a blank message must not submit");

            composer.text = "  hello  ";
            send.clicked();
            compare(submitSpy.count, 1, "a non-blank message submits once");
            compare(submitSpy.signalArguments[0][0], "hello", "the submitted text is trimmed");
            compare(composer.text, "", "the field clears after submit");

            composer.submitEnabled = false;
            composer.text = "blocked";
            send.clicked();
            compare(submitSpy.count, 1, "a gated-off composer does not submit");
        }

        // The dialog only enables Create once there is non-blank input, and emits
        // the trimmed address.
        function test_newConversationDialogValidation() {
            const dlg = createTemporaryObject(newConvDialogC, this);
            verify(dlg);
            addressSpy.target = dlg;
            addressSpy.clear();
            dlg.open();
            dlg.rightActions[0].clicked();
            compare(addressSpy.count, 0, "an empty address must not be accepted");
            dlg.close();
        }

        // The group dialog gates on a non-blank name: an empty name is a no-op,
        // a filled name emits once with the trimmed name, and an unentered
        // description comes through empty.
        function test_newGroupDialogValidation() {
            const dlg = createTemporaryObject(newGroupDialogC, this);
            verify(dlg);
            groupDetailsSpy.target = dlg;
            groupDetailsSpy.clear();
            dlg.open();

            dlg.rightActions[0].clicked();
            compare(groupDetailsSpy.count, 0, "an empty name must not be accepted");

            let nameField = null;
            const kids = dlg.contentItem.children;
            for (let i = 0; i < kids.length; ++i) {
                if (kids[i].objectName === "groupNameField") {
                    nameField = kids[i];
                    break;
                }
            }
            verify(nameField, "the group name field must be reachable");
            nameField.text = "  Book Club  ";
            dlg.rightActions[0].clicked();
            compare(groupDetailsSpy.count, 1, "a non-blank name must be accepted once");
            compare(groupDetailsSpy.signalArguments[0][0], "Book Club", "the name must be trimmed");
            compare(groupDetailsSpy.signalArguments[0][1], "", "an unentered description is empty");
        }

        // A dismissed group dialog keeps its draft; only a successful accept
        // clears it. Create is gated on both length limits, and the accept
        // guard refuses over-limit input regardless.
        function test_newGroupDialogDraftAndLimits() {
            const dlg = createTemporaryObject(newGroupDialogC, this);
            verify(dlg);
            groupDetailsSpy.target = dlg;
            groupDetailsSpy.clear();

            const nameField = findField(dlg.contentItem, "groupNameField");
            const descField = findField(dlg.contentItem, "groupDescriptionField");
            verify(nameField && descField, "both fields must be reachable");
            const create = dlg.rightActions[0];

            dlg.open();
            nameField.text = "Draft name";
            descField.text = "Draft description";
            dlg.close();
            compare(nameField.text, "Draft name", "closing keeps the name draft");
            compare(descField.text, "Draft description", "closing keeps the description draft");

            dlg.open();
            nameField.text = "x".repeat(dlg.nameLimit + 1);
            verify(!create.enabled, "Create is disabled over the name limit");
            create.clicked();
            compare(groupDetailsSpy.count, 0, "an over-limit name must not be accepted");

            nameField.text = "Valid";
            descField.text = "y".repeat(dlg.descriptionLimit + 1);
            verify(!create.enabled, "Create is disabled over the description limit");

            descField.text = "ok";
            create.clicked();
            compare(groupDetailsSpy.count, 1, "valid input accepts once");
            compare(nameField.text, "", "accept clears the name");
            compare(descField.text, "", "accept clears the description");
        }

        // A dismissed conversation dialog keeps its draft; a successful accept
        // clears it.
        function test_newConversationDialogDraft() {
            const dlg = createTemporaryObject(newConvDialogC, this);
            verify(dlg);
            addressSpy.target = dlg;
            addressSpy.clear();
            const field = findField(dlg.contentItem, "convAddressField");
            verify(field, "the address field must be reachable");

            dlg.open();
            field.text = "0xdraft";
            dlg.close();
            compare(field.text, "0xdraft", "closing keeps the address draft");

            dlg.open();
            dlg.rightActions[0].clicked();
            compare(addressSpy.count, 1, "a non-blank draft accepts");
            compare(field.text, "", "accept clears the address");
        }

        // The add-member dialog gates Add on non-blank input, keeps its draft
        // across a close, and clears on accept.
        function test_addMemberDialog() {
            const dlg = createTemporaryObject(addMemberDialogC, this);
            verify(dlg);
            addressSpy.target = dlg;
            addressSpy.clear();
            const field = findField(dlg.contentItem, "addMemberField");
            verify(field, "the address field must be reachable");

            dlg.open();
            dlg.rightActions[0].clicked();
            compare(addressSpy.count, 0, "an empty address must not be accepted");

            field.text = "0xpeer";
            dlg.close();
            compare(field.text, "0xpeer", "closing keeps the address draft");

            dlg.open();
            dlg.rightActions[0].clicked();
            compare(addressSpy.count, 1, "a non-blank draft accepts");
            compare(addressSpy.signalArguments[0][0], "0xpeer", "the address is emitted");
            compare(field.text, "", "accept clears the address");
        }

        // The Add member button reflects connectivity and requests a member add.
        function test_membersPaneAddButton() {
            const pane = instantiate(membersPaneC);
            const btn = findField(pane, "addMemberButton");
            verify(btn, "the add-member button must be reachable");
            verify(btn.enabled, "enabled when online");
            pane.online = false;
            verify(!btn.enabled, "disabled when offline");
            pane.online = true;

            addMemberReqSpy.target = pane;
            addMemberReqSpy.clear();
            btn.clicked();
            compare(addMemberReqSpy.count, 1, "clicking requests adding a member");
        }

        // A copy flashes a brief confirmation on the row that then clears.
        function test_memberDelegateCopiedFlash() {
            const del = instantiate(memberDelegateC);
            del.pending = false;
            verify(!del.copiedFlashing, "not flashing at rest");
            del.flashCopied();
            verify(del.copiedFlashing, "flashing right after a copy");
            tryCompare(del, "copiedFlashing", false, 3000, "the flash clears");
        }

        // Confirming the explainer emits confirmed() so the caller can proceed
        // with the invite and persist the "don't show again" choice.
        function test_memberAddInfoDialogConfirms() {
            const dlg = instantiate(memberAddInfoDialogC);
            confirmedSpy.target = dlg;
            confirmedSpy.clear();
            dlg.open();
            dlg.rightActions[0].clicked();
            compare(confirmedSpy.count, 1, "confirming must emit confirmed() once");
        }

        // The strip shows the newest failure and, once more than one is waiting,
        // how many there are; a single one needs no count.
        function test_statusBarCountsWhatIsWaiting() {
            const bar = createTemporaryObject(statusBarC, testRoot);
            verify(bar, "the strip must instantiate");
            const message = findField(bar, "statusMessage");
            const count = findField(bar, "statusErrorCount");
            verify(message && count, "the message and the count must be reachable");
            verify(!count.visible, "nothing waiting shows no count");

            bar.errorMessage = "Failed to add member: no key package for peer";
            bar.errorCount = 1;
            compare(message.text, "Failed to add member: no key package for peer");
            verify(!count.visible, "one failure is the one on show");

            bar.errorCount = 2;
            verify(count.visible, "a second failure earns a count");
            compare(count.text, "2 errors");
        }

        // Activating the message is the only way off the strip, so a failure
        // stays until it is read.
        function test_statusBarActivatesOnlyWhileHolding() {
            const bar = createTemporaryObject(statusBarC, testRoot);
            verify(bar, "the strip must instantiate");
            const message = findField(bar, "statusMessage");
            errorActivatedSpy.target = bar;
            errorActivatedSpy.clear();

            mouseClick(message);
            compare(errorActivatedSpy.count, 0, "a resting strip is not a control");

            bar.errorMessage = "Chat not online";
            bar.errorCount = 1;
            mouseClick(message);
            compare(errorActivatedSpy.count, 1, "a held failure activates once");
        }

        // The way to the logs is always there: it leads to the run's files as
        // much as to its failures, and a quiet run still has files.
        function test_statusBarAlwaysOffersTheLogs() {
            const bar = createTemporaryObject(statusBarC, testRoot);
            verify(bar, "the strip must instantiate");
            const button = findField(bar, "showLogsButton");
            verify(button, "the button must be reachable");
            verify(button.visible, "a resting strip still offers the logs");
            waitForRendering(bar);

            logsRequestedSpy.target = bar;
            logsRequestedSpy.clear();
            mouseClick(button);
            compare(logsRequestedSpy.count, 1, "the button asks for the list once");
        }

        // The badge counts what nobody has looked at, so a run with nothing to
        // report carries no mark at all.
        function test_statusBarBadgesTheUnseen() {
            const bar = createTemporaryObject(statusBarC, testRoot);
            const badge = findField(bar, "unseenErrorBadge");
            verify(badge, "the badge must be reachable");
            verify(!badge.visible, "nothing unseen, no badge");

            bar.errorCount = 3;
            verify(badge.visible, "an unseen failure earns a badge");

            // What clearing looks like from the view: the count goes to zero and
            // the list it counted lives on behind the button.
            bar.errorCount = 0;
            verify(!badge.visible, "opening the logs quiets the strip");
        }

        // A tab lists its own writer's runs and no one else's, which is what
        // lets two writers share one directory.
        function test_sessionLogsDialogListsOneWritersRuns() {
            const dlg = instantiate(sessionLogsDialogC);
            dlg.open();

            compare(dlg.currentWriter, 0, "the view's own log is the first tab");
            let rows = [];
            collectFields(dlg, "sessionLogRun", rows);
            compare(rows.length, 1, "chat-ui kept one run of the three listed");

            dlg.currentWriter = 1;
            rows = [];
            collectFields(dlg, "sessionLogRun", rows);
            compare(rows.length, 2, "the chat module kept the other two");
        }

        // A writer with no file of its own says why rather than being absent.
        function test_sessionLogsDialogExplainsTheWriterWithNoFile() {
            const dlg = instantiate(sessionLogsDialogC);
            dlg.open();
            findField(dlg, "logsTabBar").currentIndex = 1;
            dlg.currentWriter = 2;
            waitForRendering(dlg.contentItem);

            const pending = findField(dlg, "writerPending");
            verify(pending && pending.visible, "the tab must say why it holds nothing");
            const rows = [];
            collectFields(dlg, "sessionLogRun", rows);
            compare(rows.length, 0, "and list nothing");
        }

        // Opening from the strip should land on the failure that brought you
        // here; with none, the files are the only reason to be here.
        function test_sessionLogsDialogOpensOnWhatThereIsToSee() {
            const held = instantiate(sessionLogsDialogC);
            held.open();
            const heldTabs = findField(held, "logsTabBar");
            verify(heldTabs, "the tab bar must be reachable");
            compare(heldTabs.currentIndex, 0, "failures held, so Errors");

            const quiet = instantiate(quietLogsDialogC);
            quiet.open();
            compare(findField(quiet, "logsTabBar").currentIndex, 1, "nothing failed, so Full logs");
        }

        // Every failure is listed, a repeat counts against its row rather than
        // adding one, and the count the tab states is of occurrences.
        function test_sessionLogsDialogListsEveryFailure() {
            const dlg = instantiate(sessionLogsDialogC);
            dlg.open();
            waitForRendering(dlg.contentItem);

            compare(dlg.failureCount, 4, "three deliveries and one add");
            const rows = [];
            collectFields(dlg, "errorRow", rows);
            compare(rows.length, 2, "the repeat is one row, not three");

            const repeated = findField(rows[1], "errorMessage");
            verify(repeated, "a row's message must be reachable");
            verify(repeated.text.indexOf("×3") !== -1, "and must say how often it arrived");
        }

        // The caveat is one line until asked, because the tab that needs
        // explaining must not also be the tab with three fewer rows.
        function test_sessionLogsDialogKeepsTheCaveatShort() {
            const dlg = instantiate(sessionLogsDialogC);
            dlg.open();
            findField(dlg, "logsTabBar").currentIndex = 1;
            waitForRendering(dlg.contentItem);

            const caveat = findField(dlg, "caveatText");
            const toggle = findField(dlg, "caveatToggle");
            verify(caveat && toggle, "the caveat and its toggle must be reachable");
            const oneLine = caveat.text;
            verify(toggle.visible, "the rest is offered");

            dlg.caveatExpanded = true;
            verify(caveat.text.length > oneLine.length, "asking spells it out");
            verify(!toggle.visible, "and the offer goes away");
        }
    }
}
