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
// requirement and a test. A protects claim shows the test that holds it (never a spec id); a
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

    // Opened from a "Why?" (exo-355a): scroll to that step and mark it, so the reader
    // lands on the reasons for the line they were reading, not at the top of the page.
    property string focusStep: ""
    function showStep(step) {
        walkthrough.focusStep = String(step || "");
        Qt.callLater(walkthrough.scrollToFocus);
    }
    function scrollToFocus() {
        for (var i = 0; i < stepRepeater.count; ++i) {
            var d = stepRepeater.itemAt(i);
            if (d && d.objectName === "learnStep_" + walkthrough.focusStep) {
                var top = stack.y + d.y - Theme.spacing.large;
                flick.contentY = Math.max(0, Math.min(top, flick.contentHeight - flick.height));
                return;
            }
        }
        flick.contentY = 0;
    }

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

    // The credibility line (PriFi axis, docs/design/action-manifest.md §2): is the
    // discretion to defect removed by structure, or does it rest on a named party —
    // or on nobody at all, because the information simply reaches an unbound
    // observer? Named, never scored.
    function credibilityOf(c) {
        if (c.credibility === "imperative")
            return qsTr("IMPERATIVE — enforced by structure, proven by the test above");
        if (c.credibility === "motivational")
            return qsTr("MOTIVATIONAL — rests on %1").arg(c.party || "");
        if (c.credibility === "exposed")
            return qsTr("EXPOSED — no binding: visible to %1").arg(c.party || "");
        if (c.credibility === "not-applicable")
            return qsTr("NOT A TRUST GAP — a limit, not a party to trust");
        return "";
    }

    function credibilityColor(c) {
        if (c.credibility === "imperative")
            return Theme.palette.success;
        if (c.credibility === "motivational" || c.credibility === "exposed")
            return Theme.palette.warning;
        return Theme.palette.textTertiary;
    }

    // The evidence line, per kind — the checkable half of the claim.
    function evidenceOf(c) {
        if (c.kind === "protects")      // the test that holds it; no spec ids on screen
            return qsTr("checked by %1").arg(String(c.test).split("/").pop());
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
            // aligned like every page (exo-720.11)
            x: Theme.spacing.xxlarge
            width: Math.min(flick.width - 2 * Theme.spacing.xxlarge, 720)
            spacing: Theme.spacing.large

            PageHeader {
                title: qsTr("Learn")
                subtitle: qsTr("The transaction lifecycle: at each step, what happens, what Logos protects, where others leak, and what is still open.")
            }

            // ── one block per lifecycle step ──────────────────────────────────
            Repeater {
                id: stepRepeater
                model: registry.steps

                delegate: ColumnLayout {
                    id: stepBlock
                    readonly property string stepId: modelData.id
                    readonly property bool focused: stepBlock.stepId === walkthrough.focusStep
                    objectName: "learnStep_" + stepBlock.stepId
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small

                    LogosText {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        text: modelData.title
                        color: stepBlock.focused ? Theme.palette.primary : Theme.palette.text
                        font.family: Theme.typography.publicSans
                        font.pixelSize: Theme.typography.primaryText
                        font.weight: Theme.typography.weightBold
                        wrapMode: Text.WordWrap
                    }

                    LogosText {
                        textFormat: Text.PlainText
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
                                    textFormat: Text.PlainText
                                    text: walkthrough.kindLabel(modelData.kind)
                                    color: walkthrough.kindColor(modelData.kind)
                                    font.family: MusterStyle.mono
                                    font.pixelSize: MusterStyle.caption
                                    font.weight: Theme.typography.weightMedium
                                }

                                LogosText {
                                    textFormat: Text.PlainText
                                    Layout.fillWidth: true
                                    text: modelData.title
                                    color: Theme.palette.text
                                    font.pixelSize: Theme.typography.secondaryText
                                    font.weight: Theme.typography.weightBold
                                    wrapMode: Text.WordWrap
                                }

                                LogosText {
                                    textFormat: Text.PlainText
                                    Layout.fillWidth: true
                                    text: modelData.body
                                    color: Theme.palette.textSecondary
                                    font.pixelSize: Theme.typography.secondaryText
                                    wrapMode: Text.WordWrap
                                }

                                LogosText {
                                    textFormat: Text.PlainText
                                    Layout.fillWidth: true
                                    text: walkthrough.evidenceOf(modelData)
                                    color: Theme.palette.textTertiary
                                    font.family: MusterStyle.mono
                                    font.pixelSize: Theme.typography.secondaryText
                                    wrapMode: Text.WrapAnywhere
                                }

                                LogosText {
                                    textFormat: Text.PlainText
                                    objectName: "claimCredibility"
                                    visible: walkthrough.credibilityOf(modelData).length > 0
                                    Layout.fillWidth: true
                                    text: walkthrough.credibilityOf(modelData)
                                    color: walkthrough.credibilityColor(modelData)
                                    font.pixelSize: MusterStyle.caption
                                    font.weight: Theme.typography.weightMedium
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
