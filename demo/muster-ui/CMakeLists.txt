cmake_minimum_required(VERSION 3.14)
project(MusterUiPlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found. Set LOGOS_MODULE_BUILDER_ROOT.")
endif()

logos_module(
    NAME muster_ui
    REP_FILE src/ChatBackend.rep
    SOURCES
        src/ChatBackend.h
        src/ChatBackend.cpp
        src/MusterMessage.h
        src/ChatBackendWallet.cpp
        src/ChatBackendJourney.cpp
        src/ConversationListModel.h
        src/ConversationListModel.cpp
        src/MessageListModel.h
        src/MessageListModel.cpp
        src/MemberListModel.h
        src/MemberListModel.cpp
        src/TimeFormat.h
        src/TimeFormat.cpp
        src/Identity.h
        src/Identity.cpp
        src/SessionLogFiles.h
        src/SessionLogFiles.cpp
        src/ErrorLog.h
        src/ErrorLog.cpp
        src/RunLog.h
        src/RunLog.cpp
        src/ProcessLog.h
        src/ProcessLog.cpp
    INCLUDE_DIRS
        src
)

# Dev-only QML tooling. Registers the pure-QML ChatUi module as a proper Qt QML
# module so the generated all_qmllint target and .qmltypes can check it
# (NO_PLUGIN + linter-only: nothing here is shipped). OFF by default, so the
# build the bundle uses (Qt Core + RemoteObjects, driven by logos_module above)
# never enters this branch and the packaged .lgx is byte-identical. Enable in a
# Qt6 Qml/Quick environment with -DCHAT_UI_QML_DEVTOOLS=ON, and point qmllint at
# the design system via QML_IMPORT_PATH=<app>/lib so `import Logos.Theme`
# resolves. The runtime module identity is the hand-written src/qml/ChatUi/qmldir,
# not the qmldir this target generates.
#
# Worth turning on before touching QML: nix build does not evaluate QML, so an
# invalid property or a palette token that does not exist builds green and then
# aborts the component at window-open time, which surfaces as "Failed to load
# UI plugin" with nothing in the main log. That cost an afternoon once already.
option(CHAT_UI_QML_DEVTOOLS "Register muster-ui QML for qmllint/qmltypes (dev only, not shipped)" OFF)
if(CHAT_UI_QML_DEVTOOLS)
    find_package(Qt6 REQUIRED COMPONENTS Qml Quick)
    qt_standard_project_setup(REQUIRES 6.5)
    set_source_files_properties(src/qml/ChatUi/ChatTheme.qml
        src/qml/ChatUi/VisibilityClaims.qml
        PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
    qt_add_qml_module(chat_ui_qml_devtools
        URI ChatUi
        VERSION 1.0
        NO_PLUGIN
        QML_FILES
            src/qml/ChatUi/ChatTheme.qml
            src/qml/ChatUi/ChatStore.qml
            src/qml/ChatUi/PanelHeader.qml
            src/qml/ChatUi/DetailRow.qml
            src/qml/ChatUi/DetailsPanel.qml
            src/qml/ChatUi/ChatIconButton.qml
            src/qml/ChatUi/Avatar.qml
            src/qml/ChatUi/AccountCard.qml
            src/qml/ChatUi/EmptyState.qml
            src/qml/ChatUi/ClipboardProxy.qml
            src/qml/ChatUi/ChatMenuItem.qml
            src/qml/ChatUi/MessageComposer.qml
            src/qml/ChatUi/StatusBar.qml
            src/qml/ChatUi/MessageDelegate.qml
            src/qml/ChatUi/MusterCard.qml
            src/qml/ChatUi/VisibilityClaims.qml
            src/qml/ChatUi/VisibilityPanel.qml
            src/qml/ChatUi/SendDialog.qml
            src/qml/ChatUi/WalletCard.qml
            src/qml/ChatUi/JobStrip.qml
            src/qml/ChatUi/ScopeLine.qml
            src/qml/ChatUi/ActionsPane.qml
            src/qml/ChatUi/ActionDelegate.qml
            src/qml/ChatUi/NewActivityDialog.qml
            src/qml/ChatUi/DayChip.qml
            src/qml/ChatUi/Facepile.qml
            src/qml/ChatUi/ThreadHeader.qml
            src/qml/ChatUi/MessageSkeleton.qml
            src/qml/ChatUi/ConversationDelegate.qml
            src/qml/ChatUi/MemberDelegate.qml
            src/qml/ChatUi/ConversationsPane.qml
            src/qml/ChatUi/MessageThreadPane.qml
            src/qml/ChatUi/MembersPane.qml
            src/qml/ChatUi/NewConversationDialog.qml
            src/qml/ChatUi/NewGroupDialog.qml
            src/qml/ChatUi/MemberAddInfoDialog.qml
            src/qml/ChatUi/AddMemberDialog.qml
            src/qml/ChatUi/SelectableText.qml
            src/qml/ChatUi/SessionLogsDialog.qml
    )
endif()
