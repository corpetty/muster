import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The address book — name the ids you coordinate with, so the roster, the join
// prompt, and the composer show people instead of 64-byte hex. The module persists
// the book beside the keystore and resolves these aliases into membersJson /
// pendingJson, so a name given here shows everywhere.
//
// PURE-RENDER: reads backend.contactsJson; the only things that leave are
// addContact / setContactAlias / removeContact calls.
//
// NB (ADR-011): nix build does not evaluate QML. Restricted to Theme keys and the
// Logos.Controls types the other views already prove (LogosText, LogosButton,
// LogosTextField).
Item {
    id: book

    property var backend

    readonly property var contacts: {
        try { return JSON.parse(backend ? backend.contactsJson : "[]"); }
        catch (e) { return []; }
    }

    Component.onCompleted: if (book.backend) book.backend.loadContacts()

    // An alias another contact already has, in any case: the module refuses it
    // (contact_add / contact_set_alias, exo-3b3.18), so the form says so before Add.
    function aliasTaken(alias, exceptId) {
        var a = String(alias || "").trim().toLowerCase();
        if (a.length === 0) return "";
        var cs = book.contacts || [];
        for (var i = 0; i < cs.length; i++) {
            var c = cs[i];
            if (String(c.identity || "") !== String(exceptId || "")
                    && String(c.alias || "").toLowerCase() === a)
                return String(c.alias);
        }
        return "";
    }
    // Latin letters mixed with Cyrillic or Greek ones: "Аlice" with a Cyrillic А reads as
    // "Alice". The module flags stored aliases the same way (mixedScript).
    function mixesScripts(s) {
        var t = String(s || "");
        return /[A-Za-z\u00C0-\u024F]/.test(t) && /[\u0370-\u03FF\u0400-\u052F]/.test(t);
    }

    function shortId(id) {
        var s = String(id || "");
        return s.length > 12 ? s.substring(0, 10) + "…" : s;
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: col.implicitHeight + 2 * Theme.spacing.xlarge
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: col
            y: Theme.spacing.xlarge
            // aligned like every page (exo-720.11)
            x: Theme.spacing.xxlarge
            width: Math.min(flick.width - 2 * Theme.spacing.xxlarge, 720)
            spacing: Theme.spacing.large

            PageHeader {
                title: qsTr("Contacts")
                subtitle: qsTr("Names you give the ids you coordinate with. They stay on this device and never reach a room.")
            }

            // ── add a contact ─────────────────────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: addCol.implicitHeight + 2 * Theme.spacing.medium
                radius: Theme.spacing.radiusMedium
                color: Theme.palette.surface
                border.width: 1
                border.color: Theme.palette.borderSubtle

                ColumnLayout {
                    id: addCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.spacing.medium
                    spacing: Theme.spacing.small

                    LogosText {
                        textFormat: Text.PlainText
                        text: qsTr("Add someone")
                        color: Theme.palette.textTertiary
                        font.pixelSize: MusterStyle.caption
                        font.weight: Theme.typography.weightBold
                    }
                    LogosText {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("Paste the contact link they shared with you and give them a name.")
                        color: Theme.palette.textTertiary
                        font.pixelSize: MusterStyle.caption
                    }
                    LogosTextField {
                        id: newIdField
                        objectName: "contactIdField"
                        Layout.fillWidth: true
                        placeholderText: qsTr("their contact link")
                        font.family: MusterStyle.mono
                        // a link carries the name they suggest: offered, yours to change
                        onTextChanged: {
                            var c = MusterStyle.parseContact(text);
                            if (c && c.name.length > 0 && newAliasField.text.length === 0) newAliasField.text = c.name;
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosTextField {
                            id: newAliasField
                            objectName: "contactAliasField"
                            Layout.fillWidth: true
                            placeholderText: qsTr("name, e.g. Alice")
                        }
                        ActionButton {
                            objectName: "contactAddButton"
                            text: qsTr("Add")
                            enabled: MusterStyle.parseContact(newIdField.text) !== null && newAliasField.text.trim().length > 0
                                     && book.aliasTaken(newAliasField.text, "") === ""
                            onClicked: {
                                var c = MusterStyle.parseContact(newIdField.text);
                                if (book.backend && c)
                                    book.backend.addContact(c.id, newAliasField.text.trim());
                                newIdField.text = "";
                                newAliasField.text = "";
                            }
                        }
                    }
                    LogosText {
                        textFormat: Text.PlainText
                        objectName: "contactAliasTaken"
                        visible: book.aliasTaken(newAliasField.text, "") !== ""
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("Another contact is already named %1. Give this one a name you can tell apart.")
                                .arg(book.aliasTaken(newAliasField.text, ""))
                        color: MusterStyle.warning
                        font.pixelSize: MusterStyle.caption
                    }
                    LogosText {
                        textFormat: Text.PlainText
                        objectName: "contactAliasMixed"
                        visible: book.mixesScripts(newAliasField.text)
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("This name mixes Latin letters with Cyrillic or Greek ones, which can look like another name. A contact link suggests the name its sender chose; check it.")
                        color: MusterStyle.warning
                        font.pixelSize: MusterStyle.caption
                    }
                }
            }

            // ── the book ──────────────────────────────────────────────────────
            LogosText {
                textFormat: Text.PlainText
                visible: (book.contacts || []).length === 0
                Layout.fillWidth: true
                text: qsTr("No contacts yet. Add someone above, or name people from a room's members.")
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.secondaryText
                wrapMode: Text.WordWrap
            }

            Repeater {
                model: book.contacts

                delegate: Rectangle {
                    id: row
                    required property var modelData
                    Layout.fillWidth: true
                    implicitHeight: rowCol.implicitHeight + 2 * Theme.spacing.medium
                    radius: Theme.spacing.radiusMedium
                    color: Theme.palette.surface
                    border.width: 1
                    border.color: Theme.palette.borderSubtle

                    ColumnLayout {
                        id: rowCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.spacing.medium
                        spacing: Theme.spacing.tiny

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            LogosTextField {
                                id: aliasEdit
                                Layout.fillWidth: true
                                text: String(row.modelData.alias || "")
                                font.family: Theme.typography.publicSans
                                // LogosTextField wraps a TextInput (exposed as textInput)
                                // and has no editingFinished of its own — bind the inner
                                // one (fires on Enter or focus loss), the same seam the
                                // room composer uses for onAccepted.
                                Connections {
                                    target: aliasEdit.textInput
                                    function onEditingFinished() {
                                        var stored = String(row.modelData.alias || "");
                                        if (!book.backend || aliasEdit.text.trim() === stored) return;
                                        // a name another contact has is refused by the module too
                                        if (book.aliasTaken(aliasEdit.text, row.modelData.identity) !== "") {
                                            aliasEdit.text = stored;
                                            return;
                                        }
                                        book.backend.setContactAlias(String(row.modelData.identity || ""),
                                                                     aliasEdit.text.trim());
                                    }
                                }
                            }
                            ActionButton {
                                objectName: "contactRemove"
                                text: qsTr("Remove")
                                variant: LogosButton.Variant.Secondary
                                onClicked: if (book.backend)
                                    book.backend.removeContact(String(row.modelData.identity || ""));
                            }
                        }
                        LogosText {
                            textFormat: Text.PlainText
                            visible: row.modelData.mixedScript === true
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: qsTr("This name mixes Latin letters with Cyrillic or Greek ones: it may look like another contact's.")
                            color: MusterStyle.warning
                            font.pixelSize: MusterStyle.caption
                        }
                        LogosText {
                            textFormat: Text.PlainText
                            Layout.fillWidth: true
                            text: book.shortId(row.modelData.identity)
                            color: Theme.palette.textTertiary
                            font.family: MusterStyle.mono
                            font.pixelSize: MusterStyle.caption
                        }
                    }
                }
            }
        }
    }
}
