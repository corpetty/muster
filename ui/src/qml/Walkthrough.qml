import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// P4 — the walkthrough surface: the ADR-012 claims registry rendered as the
// transaction-lifecycle legend. Each step answers the walkthrough's four
// questions — what happened (the step summary), what Logos protects, where
// others leak, and what is still open (docs/00-vision.md).
//
// The data is ClaimsRegistry.qml, generated from contracts/claims/registry.json
// and drift-checked in CI (ui/tools/gen-claims-qml.py). This view adds no claim
// of its own — it only lays out what the registry already resolved to a
// requirement and a test. A protects claim shows its requirement id and test; a
// gap shows its fix and honest status; a comparison names the system and the
// observer. Nothing here is prose a delegate could make read fine and be wrong.
//
// NB (ADR-011): nix build does not evaluate QML. This view needs qmllint against
// the design-system import path AND a launch in the ui-host to be believed
// (docs/labbook/qml-errors-are-invisible-to-nix-build.md). It restricts itself
// to Theme keys and Logos.Controls types already used by Main.qml.
Item {
    id: walkthrough

    ClaimsRegistry { id: registry }

    function kindLabel(kind) {
        if (kind === "protects")
            return qsTr("PROTECTS");
        if (kind === "others-leak")
            return qsTr("OTHERS LEAK");
        return qsTr("GAP");
    }

    function kindColor(kind) {
        if (kind === "protects")
            return Theme.palette.success;
        if (kind === "gap")
            return Theme.palette.warning;
        return Theme.palette.textTertiary;
    }

    // The evidence line, per kind — the checkable half of the claim.
    function evidenceOf(c) {
        if (c.kind === "protects")
            return c.requirement + "  ·  " + c.test;
        if (c.kind === "others-leak")
            return c.system + "  —  " + c.observer;
        var s = c.status;
        if (c.spec_stage)
            s += "  ·  " + c.spec_stage;
        return qsTr("Fix: ") + c.fix + "\n" + s;
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: stack.implicitHeight + 2 * Theme.spacing.xlarge
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: stack
            y: Theme.spacing.xlarge
            x: (flick.width - width) / 2
            width: Math.min(flick.width - 2 * Theme.spacing.xlarge, 560)
            spacing: Theme.spacing.large

            LogosText {
                text: qsTr("The transaction lifecycle")
                color: Theme.palette.text
                font.family: Theme.typography.publicSans
                font.pixelSize: Theme.typography.subtitleText
                font.weight: Theme.typography.weightBold
                Layout.alignment: Qt.AlignHCenter
            }

            LogosText {
                Layout.fillWidth: true
                text: qsTr("Each step: what happens, what Logos protects, where others leak, and what is still open.")
                color: Theme.palette.textTertiary
                font.pixelSize: Theme.typography.secondaryText
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
            }

            // ── one block per lifecycle step ──────────────────────────────────
            Repeater {
                model: registry.steps

                delegate: ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosText {
                        Layout.fillWidth: true
                        text: modelData.title
                        color: Theme.palette.text
                        font.family: Theme.typography.publicSans
                        font.pixelSize: Theme.typography.primaryText
                        font.weight: Theme.typography.weightBold
                        wrapMode: Text.WordWrap
                    }

                    LogosText {
                        Layout.fillWidth: true
                        text: modelData.summary
                        color: Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.secondaryText
                        wrapMode: Text.WordWrap
                    }

                    // ── the claims for this step (protects → leak → gap) ──────
                    Repeater {
                        model: registry.forStep(modelData.id)

                        delegate: Rectangle {
                            objectName: "claimCard"
                            Layout.fillWidth: true
                            implicitHeight: claimCol.implicitHeight + 2 * Theme.spacing.medium
                            radius: Theme.spacing.radiusSmall
                            color: Theme.palette.surfaceRaised
                            border.width: 1
                            border.color: Theme.palette.borderSubtle

                            ColumnLayout {
                                id: claimCol
                                anchors.fill: parent
                                anchors.margins: Theme.spacing.medium
                                spacing: Theme.spacing.tiny

                                LogosText {
                                    text: walkthrough.kindLabel(modelData.kind)
                                    color: walkthrough.kindColor(modelData.kind)
                                    font.family: Theme.typography.mono
                                    font.pixelSize: Theme.typography.badgeText
                                    font.weight: Theme.typography.weightMedium
                                }

                                LogosText {
                                    Layout.fillWidth: true
                                    text: modelData.title
                                    color: Theme.palette.text
                                    font.pixelSize: Theme.typography.secondaryText
                                    font.weight: Theme.typography.weightBold
                                    wrapMode: Text.WordWrap
                                }

                                LogosText {
                                    Layout.fillWidth: true
                                    text: modelData.body
                                    color: Theme.palette.textSecondary
                                    font.pixelSize: Theme.typography.badgeText
                                    wrapMode: Text.WordWrap
                                }

                                LogosText {
                                    Layout.fillWidth: true
                                    text: walkthrough.evidenceOf(modelData)
                                    color: Theme.palette.textTertiary
                                    font.family: Theme.typography.mono
                                    font.pixelSize: Theme.typography.badgeText
                                    wrapMode: Text.WrapAnywhere
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
