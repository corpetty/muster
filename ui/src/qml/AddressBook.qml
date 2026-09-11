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
            x: (flick.width - width) / 2
            width: Math.min(flick.width - 2 * Theme.spacing.xlarge, 560)
            spacing: Theme.spacing.large

            LogosText {
                text: qsTr("Address book")
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.subtitleText
                font.weight: Theme.typography.weightBold
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
                        text: qsTr("ADD SOMEONE")
                        color: Theme.palette.textTertiary
                        font.family: Theme.typography.mono
                        font.pixelSize: Theme.typography.badgeText
                        font.weight: Theme.typography.weightMedium
                    }
                    LogosText {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("Paste the chat id they shared with you and give them a name.")
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.badgeText
                    }
                    LogosTextField {
                        id: newIdField
                        objectName: "contactIdField"
                        Layout.fillWidth: true
                        placeholderText: qsTr("their chat id (128 hex)")
                        font.family: Theme.typography.mono
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
                        LogosButton {
                            objectName: "contactAddButton"
                            text: qsTr("Add")
                            enabled: newIdField.text.length > 0 && newAliasField.text.length > 0
                            onClicked: {
                                if (book.backend)
                                    book.backend.addContact(newIdField.text.trim(),
                                                            newAliasField.text.trim());
                                newIdField.text = "";
                                newAliasField.text = "";
                            }
                        }
                    }
                }
            }

            // ── the book ──────────────────────────────────────────────────────
            LogosText {
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
                                onEditingFinished: {
                                    if (book.backend && text.trim() !== String(row.modelData.alias || ""))
                                        book.backend.setContactAlias(String(row.modelData.identity || ""),
                                                                     text.trim());
                                }
                            }
                            LogosButton {
                                objectName: "contactRemove"
                                text: qsTr("Remove")
                                variant: LogosButton.Variant.Secondary
                                onClicked: if (book.backend)
                                    book.backend.removeContact(String(row.modelData.identity || ""));
                            }
                        }
                        LogosText {
                            Layout.fillWidth: true
                            text: book.shortId(row.modelData.identity)
                            color: Theme.palette.textTertiary
                            font.family: Theme.typography.mono
                            font.pixelSize: Theme.typography.badgeText
                        }
                    }
                }
            }
        }
    }
}
