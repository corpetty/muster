pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// Modal dialog answering the two questions a run raises: what failed, and where
// the files are that say why. Two tabs, and the second splits again because
// there is no one file: each writer keeps its own log where the platform gave it
// somewhere to write.
//
// The app never reads a log's contents; a row copies paths, and everything a row
// copies is absolute.
//
// Standalone: set errors, runs and logDir, open(), and read the signals.
LogosDialog {
    id: root

    // Every failure the run reported, newest first, as the backend publishes
    // them: `when`, `message`, `count`.
    property var errors: []
    // Every run of every writer, as the backend publishes them: `writer`,
    // `label`, `sizeLabel`, `fileCount`, `path`, `paths`, `stamp`, `current`.
    property var runs: []
    // The directory the writers share, empty when no log was opened.
    property string logDir: ""

    // The failures, as a count of occurrences rather than of rows: a message
    // that repeated is one row carrying how many times it arrived.
    readonly property int failureCount: root.errors.reduce((total, entry) => total + entry.count, 0)

    // The writers, in the order the tab row offers them. `stem` is what the
    // backend tags a run with; a writer with no file yet has `pending` set and
    // explains itself instead of listing.
    readonly property var writers: [
        {
            stem: "chat_ui",
            label: "chat-ui",
            pending: false,
            blurb: qsTr("What this view wrote itself: every failure the Errors tab holds, plus the warnings its QML and the view host produced."),
            caveat: qsTr("Borrowed from the chat module, because a view module is handed no instance path."),
            caveatMore: qsTr("This is the chat module's directory, not one this view chose. A view module is not a module as far as the platform is concerned, so it is assigned no instance directory of its own, and picking one would mean two instances of the app writing into the same folder. Borrowing the module's is per-instance correct because the platform assigned it, and until LogosUiPluginContext hands over a path of its own, this log lives next to the one it belongs beside anyway."),
            pendingReason: ""
        },
        {
            stem: "chat_module",
            label: "chat-module",
            pending: false,
            blurb: qsTr("What the chat core wrote, at the level this app asked for: the module, libchat and its client, plus a crash from anywhere in the core."),
            caveat: "",
            caveatMore: "",
            pendingReason: ""
        },
        {
            stem: "delivery_module",
            label: "delivery",
            pending: true,
            blurb: "",
            caveat: "",
            caveatMore: "",
            pendingReason: qsTr("delivery_module writes its diagnostics straight to stderr, and the delivery node embedded in it logs to stdout through a logger whose level is fixed when the library is compiled. Both streams go wherever the process was started from, so there is no file for this tab to name. Giving delivery a log of its own is a change in delivery-module, and is deferred.")
        }
    ]

    // Which writer's runs the Full logs tab is showing.
    property int currentWriter: 0
    readonly property var writer: root.writers[root.currentWriter]
    readonly property var writerRuns: root.runs.filter(run => run.writer === root.writer.stem)
    // Whether the caveat is spelled out. One line by default: the row budget is
    // the scarce thing here, and the rest is a click away.
    property bool caveatExpanded: false

    title: qsTr("Logs")
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape
    anchors.centerIn: Overlay.overlay
    width: Math.min(620, (Overlay.overlay ? Overlay.overlay.width : 620) - 2 * Theme.spacing.large)

    // A reader who came from the strip is looking for the failure they just saw;
    // with nothing to show them, the files are the only reason to be here.
    onAboutToShow: {
        tabs.currentIndex = root.failureCount > 0 ? 0 : 1;
        root.caveatExpanded = false;
    }

    rightActions: [
        LogosButton {
            implicitWidth: 96
            implicitHeight: 36
            text: qsTr("Close")
            onClicked: root.close()
        }
    ]

    ClipboardProxy {
        id: clipboard
    }

    contentItem: ColumnLayout {
        spacing: Theme.spacing.medium

        LogosTabBar {
            id: tabs
            objectName: "logsTabBar"
            Layout.fillWidth: true

            LogosTabButton {
                objectName: "errorsTab"
                text: qsTr("Errors")
            }
            LogosTabButton {
                objectName: "fullLogsTab"
                //: Tab holding the log files, as against the list of failures
                text: qsTr("Full logs")
            }
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 320
            currentIndex: tabs.currentIndex

            // ── what failed ──────────────────────────────────────────────
            ColumnLayout {
                spacing: Theme.spacing.small

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosText {
                        objectName: "errorsSummary"
                        Layout.fillWidth: true
                        text: {
                            if (root.failureCount === 0)
                                return qsTr("Nothing has failed this run.");
                            //: The run reported exactly one failure
                            if (root.failureCount === 1)
                                return qsTr("1 failure");
                            //: How many failures the run reported, newest first
                            return qsTr("%1 failures, newest first").arg(root.failureCount);
                        }
                        color: Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.secondaryText
                        wrapMode: Text.WordWrap
                    }

                    LogosButton {
                        objectName: "copyAllErrorsButton"
                        visible: root.failureCount > 0
                        // Padding first, then size from it. LogosButton's floors
                        // are for a dialog action, and this sits inline against a
                        // line of text; pinning a height against the default
                        // padding instead would leave the label no room and it
                        // would ride below the pill's centre.
                        topPadding: Theme.spacing.small
                        bottomPadding: Theme.spacing.small
                        leftPadding: Theme.spacing.medium
                        rightPadding: Theme.spacing.medium
                        implicitWidth: implicitContentWidth + leftPadding + rightPadding
                        implicitHeight: implicitContentHeight + topPadding + bottomPadding
                        //: Copies every failure of the run, one per line
                        text: qsTr("Copy all")
                        onClicked: clipboard.copy(root.errors.map(entry => entry.count > 1 ? "%1  %2 ×%3".arg(entry.when).arg(entry.message).arg(entry.count) : "%1  %2".arg(entry.when).arg(entry.message)).join("\n"))
                    }
                }

                EmptyState {
                    objectName: "noErrors"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: root.failureCount === 0
                    // An empty tab is a dead end, and the files are the reason
                    // the dialog is worth having open.
                    text: qsTr("The run's log files are under Full logs.")
                    verticalAlignment: Text.AlignVCenter
                }

                LogosScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: root.failureCount > 0

                    ListView {
                        objectName: "errorList"
                        spacing: Theme.spacing.tiny
                        model: root.errors
                        clip: true

                        delegate: Rectangle {
                            id: errorRow
                            objectName: "errorRow"

                            required property var modelData
                            required property int index

                            width: ListView.view ? ListView.view.width : 0
                            implicitHeight: errorLayout.implicitHeight + 2 * Theme.spacing.small
                            radius: Theme.spacing.radiusSmall
                            // The one the strip was holding, so opening the
                            // dialog shows which line brought you here.
                            color: errorRow.index === 0 ? Theme.palette.surfaceRaised : "transparent"
                            border.width: 1
                            border.color: Theme.palette.borderSubtle

                            RowLayout {
                                id: errorLayout
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: Theme.spacing.small
                                anchors.rightMargin: Theme.spacing.small
                                spacing: Theme.spacing.small

                                LogosText {
                                    Layout.alignment: Qt.AlignTop
                                    text: errorRow.modelData.when
                                    font.family: Theme.typography.mono
                                    font.pixelSize: Theme.typography.secondaryText
                                    color: Theme.palette.textMuted
                                }

                                LogosText {
                                    objectName: "errorMessage"
                                    Layout.fillWidth: true
                                    // Wraps rather than elides: the tail is
                                    // often the module's own words, and that is
                                    // the part a reader needs.
                                    text: errorRow.modelData.count > 1 ? "%1 ×%2".arg(errorRow.modelData.message).arg(errorRow.modelData.count) : errorRow.modelData.message
                                    textFormat: Text.PlainText
                                    color: Theme.palette.text
                                    font.pixelSize: Theme.typography.secondaryText
                                    wrapMode: Text.WordWrap
                                }

                                ChatIconButton {
                                    id: copyError
                                    objectName: "copyErrorButton"
                                    Layout.alignment: Qt.AlignTop
                                    size: 24
                                    iconSize: 12
                                    iconSource: Qt.resolvedUrl("icons/copy.png")
                                    Accessible.role: Accessible.Button
                                    Accessible.name: qsTr("Copy this failure")
                                    onClicked: clipboard.copy(errorRow.modelData.message)

                                    LogosToolTip {
                                        text: qsTr("Copy this failure")
                                        placement: LogosToolTip.Left
                                        visible: copyError.hovered
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ── the files ────────────────────────────────────────────────
            ColumnLayout {
                spacing: Theme.spacing.small

                RowLayout {
                    objectName: "writerTabs"
                    Layout.fillWidth: true
                    spacing: Theme.spacing.tiny

                    Repeater {
                        model: root.writers

                        delegate: Rectangle {
                            id: writerPill
                            objectName: "writerTab"

                            required property var modelData
                            required property int index

                            readonly property bool selected: writerPill.index === root.currentWriter
                            readonly property int runCount: root.runs.filter(run => run.writer === writerPill.modelData.stem).length

                            implicitWidth: writerLabel.implicitWidth + 2 * Theme.spacing.medium
                            implicitHeight: 26
                            radius: Theme.spacing.radiusPill
                            color: writerPill.selected ? Theme.palette.overlayLight : "transparent"
                            border.width: 1
                            border.color: writerPill.selected ? Theme.palette.borderDark : "transparent"
                            Accessible.role: Accessible.PageTab
                            Accessible.name: writerPill.modelData.label
                            Accessible.onPressAction: root.currentWriter = writerPill.index

                            RowLayout {
                                id: writerLabel
                                anchors.centerIn: parent
                                spacing: 6

                                LogosText {
                                    text: writerPill.modelData.label
                                    font.pixelSize: Theme.typography.secondaryText
                                    color: writerPill.selected ? Theme.palette.text : Theme.palette.textTertiary
                                }

                                LogosText {
                                    text: {
                                        if (writerPill.modelData.pending) {
                                            //: A writer whose log this dialog cannot reach yet
                                            return qsTr("TBD");
                                        }
                                        //: The log directory holds exactly one run of this writer
                                        if (writerPill.runCount === 1)
                                            return qsTr("1 run");
                                        //: How many runs of one writer the log directory holds
                                        return qsTr("%1 runs").arg(writerPill.runCount);
                                    }
                                    font.pixelSize: Theme.typography.secondaryText
                                    color: writerPill.modelData.pending ? Theme.palette.warning : Theme.palette.textMuted
                                }
                            }

                            TapHandler {
                                onTapped: root.currentWriter = writerPill.index
                            }

                            HoverHandler {
                                cursorShape: Qt.PointingHandCursor
                            }
                        }
                    }
                }

                // A writer with no file of its own says why rather than being
                // absent: absence is what would need explaining.
                Rectangle {
                    objectName: "writerPending"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: root.writer.pending
                    radius: Theme.spacing.radiusSmall
                    color: "transparent"
                    border.width: 1
                    border.color: Theme.palette.borderDark

                    LogosText {
                        anchors.fill: parent
                        anchors.margins: Theme.spacing.medium
                        text: root.writer.pendingReason
                        color: Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.secondaryText
                        wrapMode: Text.WordWrap
                        verticalAlignment: Text.AlignTop
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: !root.writer.pending
                    spacing: Theme.spacing.small

                    LogosText {
                        Layout.fillWidth: true
                        text: root.writer.blurb
                        color: Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.secondaryText
                        wrapMode: Text.WordWrap
                    }

                    // Drawn only where something is unresolved, so a tab without
                    // one reads as settled rather than as undocumented.
                    Rectangle {
                        objectName: "writerCaveat"
                        Layout.fillWidth: true
                        visible: root.writer.caveat !== ""
                        implicitHeight: caveatLayout.implicitHeight + 2 * Theme.spacing.small
                        radius: Theme.spacing.radiusSmall
                        color: Theme.palette.backgroundMuted
                        border.width: 1
                        border.color: Theme.palette.borderDark

                        RowLayout {
                            id: caveatLayout
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Theme.spacing.small
                            anchors.rightMargin: Theme.spacing.small
                            spacing: Theme.spacing.small

                            LogosText {
                                Layout.alignment: Qt.AlignTop
                                //: Marks a caveat about where a log lives that is still open
                                text: qsTr("OPEN")
                                font.pixelSize: Theme.typography.badgeText
                                color: ChatTheme.signal
                            }

                            LogosText {
                                objectName: "caveatText"
                                Layout.fillWidth: true
                                text: root.caveatExpanded ? root.writer.caveatMore : root.writer.caveat
                                color: Theme.palette.textSecondary
                                font.pixelSize: Theme.typography.secondaryText
                                wrapMode: Text.WordWrap
                            }

                            LogosText {
                                objectName: "caveatToggle"
                                Layout.alignment: Qt.AlignTop
                                visible: !root.caveatExpanded
                                //: Reveals the rest of a one-line caveat
                                text: qsTr("why?")
                                font.pixelSize: Theme.typography.secondaryText
                                font.underline: true
                                color: ChatTheme.signal

                                TapHandler {
                                    onTapped: root.caveatExpanded = true
                                }

                                HoverHandler {
                                    cursorShape: Qt.PointingHandCursor
                                }
                            }
                        }
                    }

                    // The folder is the same for every row of a tab, so it is
                    // hoisted out of them and copied once. A row still copies
                    // absolute paths, so this is a convenience and not the only
                    // way to one.
                    Rectangle {
                        objectName: "logDirRow"
                        Layout.fillWidth: true
                        visible: root.logDir !== ""
                        implicitHeight: dirLayout.implicitHeight + 2 * Theme.spacing.small
                        radius: Theme.spacing.radiusSmall
                        color: Theme.palette.backgroundInset
                        border.width: 1
                        border.color: Theme.palette.borderSubtle

                        RowLayout {
                            id: dirLayout
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Theme.spacing.small
                            anchors.rightMargin: Theme.spacing.small
                            spacing: Theme.spacing.small

                            LogosText {
                                Layout.fillWidth: true
                                text: root.logDir
                                font.family: Theme.typography.mono
                                font.pixelSize: Theme.typography.secondaryText
                                color: Theme.palette.textSecondary
                                elide: Text.ElideMiddle
                            }

                            ChatIconButton {
                                id: copyDir
                                objectName: "copyLogDirButton"
                                size: 24
                                iconSize: 12
                                iconSource: Qt.resolvedUrl("icons/copy.png")
                                Accessible.role: Accessible.Button
                                Accessible.name: qsTr("Copy the folder")
                                onClicked: clipboard.copy(root.logDir)

                                LogosToolTip {
                                    text: qsTr("Copy the folder")
                                    placement: LogosToolTip.Left
                                    visible: copyDir.hovered
                                }
                            }
                        }
                    }

                    EmptyState {
                        objectName: "noRuns"
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: root.writerRuns.length === 0
                        text: qsTr("No log was opened for this writer. The Errors tab says why.")
                        verticalAlignment: Text.AlignVCenter
                    }

                    // One row per run, however many files it rotated through, so
                    // the list grows with use rather than with noise: a hundred
                    // runs is ordinary, which is why it is a ListView.
                    LogosScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: root.writerRuns.length > 0

                        ListView {
                            objectName: "runList"
                            spacing: Theme.spacing.tiny
                            model: root.writerRuns
                            clip: true

                            delegate: Rectangle {
                                id: runRow
                                objectName: "sessionLogRun"

                                required property var modelData

                                width: ListView.view ? ListView.view.width : 0
                                implicitHeight: runLayout.implicitHeight + 2 * Theme.spacing.small
                                radius: Theme.spacing.radiusSmall
                                color: runRow.modelData.current ? Theme.palette.surfaceRaised : "transparent"
                                border.width: 1
                                border.color: Theme.palette.borderSubtle

                                RowLayout {
                                    id: runLayout
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Theme.spacing.small
                                    anchors.rightMargin: Theme.spacing.small
                                    spacing: Theme.spacing.small

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        RowLayout {
                                            spacing: Theme.spacing.tiny

                                            LogosText {
                                                text: runRow.modelData.label
                                                font.pixelSize: Theme.typography.primaryText
                                                color: Theme.palette.text
                                            }

                                            LogosText {
                                                visible: runRow.modelData.current
                                                //: Marks the log of the run that is still going
                                                text: qsTr("this run")
                                                font.pixelSize: Theme.typography.secondaryText
                                                color: ChatTheme.signal
                                            }

                                            LogosText {
                                                text: runRow.modelData.fileCount > 1 ? qsTr("%1 · %2 files").arg(runRow.modelData.sizeLabel).arg(runRow.modelData.fileCount) : runRow.modelData.sizeLabel
                                                font.pixelSize: Theme.typography.secondaryText
                                                color: Theme.palette.textTertiary
                                            }
                                        }

                                        LogosText {
                                            Layout.fillWidth: true
                                            // The file name alone: the folder is
                                            // the row above, the same for every
                                            // row here.
                                            text: runRow.modelData.path.split("/").pop()
                                            font.family: Theme.typography.mono
                                            font.pixelSize: Theme.typography.secondaryText
                                            color: Theme.palette.textMuted
                                            elide: Text.ElideMiddle
                                        }
                                    }

                                    ChatIconButton {
                                        id: copyRun
                                        objectName: "copyLogPathButton"
                                        size: 24
                                        iconSize: 12
                                        iconSource: Qt.resolvedUrl("icons/copy.png")
                                        Accessible.role: Accessible.Button
                                        Accessible.name: qsTr("Copy this run's paths")
                                        // Every file of the run, so a rotated one
                                        // is handed over whole.
                                        onClicked: clipboard.copy(runRow.modelData.paths)

                                        LogosToolTip {
                                            text: qsTr("Copy this run's paths")
                                            placement: LogosToolTip.Left
                                            visible: copyRun.hovered
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
