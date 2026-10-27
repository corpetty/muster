import QtQuick
import QtQuick.Layouts
import Logos.Theme
import Logos.Controls

// Where your room identity is kept (exo-833): Muster's own keyfile on this device, or your
// Basecamp wallet, from the recovery phrase it already keeps. Moving it is asked of the
// wallet (identity_platform_request) and decided by you in the keys app (evm_keystore_ui),
// which this opens on the request (keystore.accounts.open {handle}); Muster never sees the
// phrase or the key. Each room knows you by your identity, so it moves only before you join
// one. Once in the wallet it is unlocked for Muster alone; when that runs out, room messages
// are refused until you unlock it again here.
ColumnLayout {
    id: holder
    property var backend: null
    property bool advanced: false
    spacing: Theme.spacing.tiny

    readonly property var st: {
        try { return JSON.parse(backend ? backend.identityPlatformJson : "{}") || ({}); }
        catch (e) { return ({}); }
    }
    readonly property var asked: {
        try { return JSON.parse(backend ? backend.identityAskJson : "{}") || ({}); }
        catch (e) { return ({}); }
    }
    readonly property bool onPlatform: String(st.backend || "").indexOf("platform:") === 0
    readonly property bool waiting: st.state === "waiting"
    readonly property bool canRaise: typeof logos !== "undefined" && !!logos && typeof logos.request === "function"
    property var raised: ({})          // handle → true once the keys app was asked to show it
    property string note: ""
    property var ended: ({})           // the last ask that ended with nothing to collect

    Timer {
        interval: holder.waiting ? 1500 : 5000
        repeat: true
        triggeredOnStart: true
        running: holder.visible && !!holder.backend
        onTriggered: holder.backend.loadIdentityPlatform()
    }
    onStChanged: {
        if (st.state === "waiting" && st.handle && !raised[st.handle]) openKeysApp(String(st.handle));
        if (st.state === "ended") ended = st;
        if (st.state === "waiting" || st.state === "ready") ended = ({});
    }

    function openKeysApp(handle) {
        var r = raised; r[handle] = true; raised = r;
        if (!canRaise) {
            note = qsTr("Open the Keystore app from Basecamp and approve Muster's request there.");
            return;
        }
        note = "";
        logos.request("keystore.accounts.open", { handle: handle }, function (res) {
            var e = String((res && res.error) || "");
            if (e === "unavailable" || e === "cancelled")
                holder.note = qsTr("No keys app answered: install or open Keystore (evm_keystore_ui), then approve there.");
            else if (e.length > 0 && e !== "rejected")
                holder.note = qsTr("The keys app could not be opened (%1). Open Keystore by hand.").arg(e);
        });
    }

    LogosText {
        Layout.topMargin: Theme.spacing.small
        text: qsTr("Your room identity")
        color: Theme.palette.textTertiary
        font.pixelSize: MusterStyle.caption
        font.weight: Theme.typography.weightBold
    }
    LogosText {
        objectName: "identityHolderWhere"
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: holder.onPlatform ? qsTr("Kept in your Basecamp wallet, from its recovery phrase. Muster asks it to sign; it never holds the key.")
                                : qsTr("Kept by Muster on this device.")
        color: Theme.palette.textSecondary
        font.pixelSize: Theme.typography.secondaryText
    }
    LogosText {
        objectName: "identityHolderKey"
        Layout.fillWidth: true
        visible: holder.advanced && holder.onPlatform
        wrapMode: Text.WrapAnywhere
        text: String(holder.st.publicKey || "")
        color: Theme.palette.textTertiary
        font.family: MusterStyle.mono
        font.pixelSize: MusterStyle.caption
    }

    // ── locked: muster's unlock ran out ──
    LogosText {
        objectName: "identityHolderLocked"
        Layout.fillWidth: true
        visible: holder.onPlatform && holder.st.locked === true && !holder.waiting
        wrapMode: Text.WordWrap
        text: qsTr("Locked: Muster can't sign your room messages until you unlock it for Muster in the keys app.")
        color: Theme.palette.warning
        font.pixelSize: MusterStyle.caption
    }
    ActionButton {
        objectName: "identityHolderUnlock"
        visible: holder.onPlatform && holder.st.locked === true && !holder.waiting
        text: qsTr("Unlock it for Muster")
        variant: LogosButton.Variant.Secondary
        onClicked: if (holder.backend) holder.backend.identityPlatformUnlock()
    }

    // ── moving it to the wallet ──
    ActionButton {
        objectName: "identityHolderMove"
        visible: !holder.onPlatform && holder.st.changeable === true && !holder.waiting
        text: qsTr("Keep it in my Basecamp wallet")
        variant: LogosButton.Variant.Secondary
        onClicked: if (holder.backend) holder.backend.identityPlatformRequest()
    }
    LogosText {
        Layout.fillWidth: true
        visible: !holder.onPlatform && holder.st.changeable !== undefined
        wrapMode: Text.WordWrap
        text: holder.st.changeable === true
              ? qsTr("Your wallet makes a key for Muster alone from the phrase it already keeps, so a restore brings it back. "
                     + "You approve it in the keys app. Only before you join a room: each room knows you by this key.")
              : qsTr("It can move to your wallet only before you join a room: each room knows you by this key.")
        color: Theme.palette.textTertiary
        font.pixelSize: MusterStyle.caption
    }

    // ── an ask in flight, or how the last one ended ──
    RowLayout {
        visible: holder.waiting
        spacing: Theme.spacing.small
        LogosText {
            objectName: "identityHolderWaiting"
            text: holder.st.kind === "unlock" ? qsTr("Waiting for you to unlock it in the keys app…")
                                              : qsTr("Waiting for you to approve it in the keys app…")
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.caption
        }
        ActionButton {
            objectName: "identityHolderOpenKeys"
            text: qsTr("Open the keys app")
            variant: LogosButton.Variant.Secondary
            onClicked: holder.openKeysApp(String(holder.st.handle || ""))
        }
    }
    LogosText {
        objectName: "identityHolderNote"
        Layout.fillWidth: true
        visible: text.length > 0
        wrapMode: Text.WordWrap
        text: {
            if (holder.note.length > 0) return holder.note;
            if (holder.ended.state === "ended") {
                var r = String(holder.ended.reason || "");
                return r === "rejected" ? qsTr("You turned it down in the keys app. Nothing changed.")
                     : r === "expired_no_ack" ? qsTr("The request expired before it was opened. Ask again.")
                     : qsTr("The request ended (%1). Nothing changed.").arg(r);
            }
            if (holder.st.state === "ready" && holder.st.applied === false)
                return String(holder.st.detail || qsTr("The key was made, but Muster could not switch to it."));
            if (holder.asked.ok === false)
                return holder.asked.install
                    ? qsTr("Your Basecamp has no signer manager (%1), so it can't hold a room identity yet.").arg(String(holder.asked.install))
                    : holder.advanced ? String(holder.asked.error || "")
                                      : qsTr("Your Basecamp wallet can't hold a room identity yet. Advanced says why.");
            return "";
        }
        color: Theme.palette.warning
        font.pixelSize: MusterStyle.caption
    }
}
