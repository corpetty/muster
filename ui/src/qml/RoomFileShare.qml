import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs

import Logos.Theme
import Logos.Controls

// FileShare (exo-4d0, docs/design/room-swarm.md): files shared in this room. A file is sealed
// on this machine under a key only the room holds, and its sealed blob moves through Logos
// Storage. The list is folded from the room's log (fileshare_files): a member is shown as
// seeding a file only because they said so. Every action is the module's; this view polls
// fileShareJson while it is shown and says what each choice reveals.
ColumnLayout {
    id: fs
    required property var backend
    // the Room: it raises Basecamp's packages.install (packageInstallRequested) and hands the
    // answers back in packageRequests, as for a card's install remedy (exo-dcc.10)
    property var room: null
    spacing: Theme.spacing.medium

    readonly property var state: {
        try { return JSON.parse(fs.backend ? (fs.backend.fileShareJson || "{}") : "{}"); }
        catch (e) { return {}; }
    }
    readonly property var result: {
        var r = fs.backend ? String(fs.backend.fileShareResultJson || "") : "";
        if (r.length === 0 || r === "ok") return {};
        try { return JSON.parse(r); } catch (e) { return {}; }
    }
    readonly property bool ready: fs.state.ready === true
    readonly property string readiness: String(fs.state.state || "")
    readonly property string install: String(fs.state.install || "")
    readonly property var installReq: (fs.room && fs.install.length > 0 && fs.room.packageRequests)
                                      ? (fs.room.packageRequests[fs.install] || null) : null
    function installNote() {
        var r = fs.installReq, pkg = fs.install;
        if (!r) return "";
        if (r.state === "asking") return qsTr("Asking Package Manager to open %1…").arg(pkg);
        if (r.state === "open") return qsTr("Package Manager is open on %1. Confirm the install there; this tab updates once it is installed.").arg(pkg);
        if (r.state === "unavailable") return qsTr("Install %1 from Basecamp's Package Manager.").arg(pkg);
        if (r.state === "failed") return qsTr("%1 was not found in your catalogues. Check the catalogues in Package Manager.").arg(pkg);
        if (r.state === "cancelled") return qsTr("The install request was cancelled.");
        return qsTr("Package Manager did not answer (%1). Install %2 from Basecamp's Package Manager.").arg(String(r.error || "")).arg(pkg);
    }
    readonly property var files: (fs.state.files || []).filter(function (f) { return !f.retracted; })
    readonly property var ops: fs.state.ops || []

    function human(n) {
        n = Number(n || 0);
        if (n < 1024) return n + " B";
        if (n < 1048576) return (n / 1024).toFixed(1) + " KB";
        if (n < 1073741824) return (n / 1048576).toFixed(1) + " MB";
        return (n / 1073741824).toFixed(2) + " GB";
    }
    function who(alias, self, id) {
        if (self) return qsTr("you");
        if (alias && String(alias).length > 0) return String(alias);
        return String(id || "").substring(0, 8) + "…";
    }
    function opFor(fileId) {
        for (var i = fs.ops.length - 1; i >= 0; i--)
            if (fs.ops[i].file === fileId && fs.ops[i].kind === "fetch") return fs.ops[i];
        return null;
    }
    // a picked file or folder, as the module reads a path: file:///a%20b → /a b
    function localPath(url) {
        var s = String(url || "");
        if (s.indexOf("file://") === 0) s = decodeURIComponent(s.substring(7));
        return s;
    }

    FileDialog {
        id: filePicker
        title: qsTr("Choose a file to share")
        fileMode: FileDialog.OpenFile
        onAccepted: pathField.text = fs.localPath(selectedFile)
    }
    FolderDialog {
        id: folderPicker
        title: qsTr("Choose where to save")
        onAccepted: folderField.text = fs.localPath(selectedFolder)
    }

    Timer {
        interval: 2000; repeat: true; triggeredOnStart: true
        running: fs.visible && fs.backend !== null
        onTriggered: fs.backend.loadFileShare()
    }

    LogosText {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: Theme.palette.textSecondary
        font.pixelSize: MusterStyle.caption
        text: qsTr("Files shared in this room are sealed on the sharer's machine under a key only the room holds. Storage nodes move a sealed blob: they never see the file, its name or its key.")
    }

    InlineNotice {
        objectName: "fileShareNotReady"
        Layout.fillWidth: true
        visible: !fs.ready
        tone: fs.readiness === "failed" ? "error" : fs.readiness === "not-installed" ? "needs" : "waiting"
        title: fs.readiness === "not-installed" ? qsTr("Logos Storage is not installed")
             : fs.readiness === "failed" ? qsTr("Logos Storage is not working")
             : fs.readiness === "not-running" ? qsTr("Logos Storage is not running yet")
             : qsTr("FileShare is getting ready")
        text: String(fs.state.note || qsTr("Checking for a storage node…"))
              + (fs.installNote().length > 0 ? "\n" + fs.installNote() : "")
        ActionButton {
            objectName: "fileShareInstall"
            visible: fs.install.length > 0 && fs.room !== null
            enabled: !fs.installReq || fs.installReq.state !== "asking"
            text: qsTr("Install Logos Storage")
            onClicked: fs.room.packageInstallRequested(fs.install)
        }
    }

    // ── share ───────────────────────────────────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        enabled: fs.ready
        LogosTextField {
            id: pathField
            objectName: "fileSharePath"
            Layout.fillWidth: true
            placeholderText: qsTr("Choose a file, or paste its path")
        }
        ActionButton {
            objectName: "fileShareChoose"
            text: qsTr("Choose a file…")
            variant: LogosButton.Variant.Secondary
            onClicked: filePicker.open()
        }
        ActionButton {
            objectName: "fileShareShare"
            text: qsTr("Share")
            enabled: pathField.text.length > 0
            onClicked: { fs.backend.shareFile(pathField.text); pathField.text = ""; }
        }
    }
    InlineNotice {
        Layout.fillWidth: true
        visible: fs.result.error !== undefined
        tone: "error"
        title: qsTr("That did not work")
        text: String(fs.result.error || "") + (fs.result.detail ? ": " + fs.result.detail : "")
    }
    Repeater {
        model: fs.ops.filter(function (o) { return o.kind === "share" && o.state !== "done"; })
        delegate: LogosText {
            required property var modelData
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            font.pixelSize: MusterStyle.caption
            color: modelData.state === "failed" ? MusterStyle.refused : Theme.palette.textSecondary
            text: modelData.state === "failed"
                  ? qsTr("Could not share %1: %2").arg(modelData.name).arg(modelData.error)
                  : qsTr("Sealing and uploading %1…").arg(modelData.name)
        }
    }

    // ── the room's files ────────────────────────────────────────────────────
    SectionHeader { Layout.fillWidth: true; text: qsTr("In this room"); count: String(fs.files.length) }
    LogosText {
        visible: fs.files.length === 0
        color: Theme.palette.textSecondary
        font.pixelSize: MusterStyle.caption
        text: qsTr("No files yet.")
    }
    RowLayout {
        Layout.fillWidth: true
        visible: fs.files.length > 0
        LogosTextField {
            id: folderField
            objectName: "fileShareFolder"
            Layout.fillWidth: true
            placeholderText: qsTr("Save to your Downloads folder, or choose another")
        }
        ActionButton {
            objectName: "fileShareChooseFolder"
            text: qsTr("Choose folder…")
            variant: LogosButton.Variant.Secondary
            onClicked: folderPicker.open()
        }
    }
    Repeater {
        model: fs.files
        delegate: ColumnLayout {
            id: row
            required property var modelData
            required property int index
            readonly property var op: fs.opFor(modelData.id)
            Layout.fillWidth: true
            spacing: Theme.spacing.small

            RowLayout {
                Layout.fillWidth: true
                LogosText {
                    Layout.fillWidth: true
                    elide: Text.ElideMiddle
                    color: Theme.palette.text
                    font.pixelSize: MusterStyle.body
                    font.weight: Theme.typography.weightBold
                    text: row.modelData.name
                }
                LogosText {
                    color: Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.caption
                    text: fs.human(row.modelData.size)
                }
            }
            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
                text: {
                    var seeders = (row.modelData.seeders || []).map(function (s) { return fs.who(s.alias, s.self, s.member); });
                    return qsTr("Shared by %1 · seeded by %2")
                           .arg(fs.who(row.modelData.sharerAlias, row.modelData.self, row.modelData.sharer))
                           .arg(seeders.length > 0 ? seeders.join(", ") : qsTr("nobody right now"));
                }
            }
            LogosText {
                Layout.fillWidth: true
                visible: row.op !== null
                wrapMode: Text.WordWrap
                font.pixelSize: MusterStyle.caption
                color: row.op && row.op.state === "failed" ? MusterStyle.refused : Theme.palette.textSecondary
                text: {
                    var o = row.op;
                    if (!o) return "";
                    if (o.state === "done") return qsTr("Saved to %1").arg(o.dest);
                    if (o.state === "failed") return qsTr("Not saved: %1").arg(o.error);
                    var pct = Number(o.total) > 0 ? Math.floor(100 * Number(o.bytes) / Number(o.total)) + "%" : "";
                    return (o.private ? qsTr("Fetching privately over Mix… %1") : qsTr("Fetching… %1")).arg(pct);
                }
            }
            RowLayout {
                Layout.fillWidth: true
                enabled: fs.ready
                readonly property bool busy: row.op !== null && row.op.state === "running"
                readonly property bool failed: row.op !== null && row.op.state === "failed"
                // held: save another copy wherever; not yet: fetch, or try again after a failure
                ActionButton {
                    objectName: "fileShareFetch_" + row.index
                    visible: !parent.busy
                    text: row.modelData.held ? qsTr("Save a copy") : parent.failed ? qsTr("Try again") : qsTr("Fetch")
                    variant: LogosButton.Variant.Secondary
                    onClicked: fs.backend.fetchFile(row.modelData.id, folderField.text, "false")
                }
                ActionButton {
                    objectName: "fileShareFetchPrivate_" + row.index
                    visible: !row.modelData.held && !parent.busy
                    text: parent.failed && row.op.private ? qsTr("Try again privately") : qsTr("Fetch privately")
                    variant: LogosButton.Variant.Secondary
                    onClicked: fs.backend.fetchFile(row.modelData.id, folderField.text, "true")
                }
                ActionButton {
                    objectName: "fileShareSeed_" + row.index
                    visible: row.modelData.held
                    text: row.modelData.seeding ? qsTr("Stop seeding") : qsTr("Seed")
                    variant: LogosButton.Variant.Secondary
                    onClicked: fs.backend.seedFile(row.modelData.id, row.modelData.seeding ? "false" : "true")
                }
                ActionButton {
                    objectName: "fileShareRetract_" + row.index
                    visible: row.modelData.self
                    text: qsTr("Remove from list")
                    variant: LogosButton.Variant.Secondary
                    onClicked: fs.backend.retractFile(row.modelData.id)
                }
            }
            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.palette.borderSubtle }
        }
    }

    // ── what each choice reveals (docs/design/room-swarm.md §5.5) ───────────
    SectionHeader { Layout.fillWidth: true; text: qsTr("Who sees what") }
    LogosText {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: Theme.palette.textSecondary
        font.pixelSize: MusterStyle.caption
        text: qsTr("The room sees each file's name and size, who shared it, and who seeds it with their storage node's address. "
                 + "Fetching seeds the file afterwards: the storage network then lists your node as holding the sealed blob, and nodes that fetch it from you see your address. "
                 + "A private fetch goes over Mix instead (slow: about 15 KB/s), dials no one, and seeds nothing. "
                 + "Removing a file from the list does not unshare it: members who fetched it keep it.")
    }
}
