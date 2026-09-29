import QtQuick

// T1's one QML file: binds a nimside qobject: property both ways and calls a slot.
// `backend` is the Nim object, set as a context property before this loads.
Window {
    id: root
    // Offscreen (the self-test) it is never shown; on a display it is a normal window.
    visible: Qt.platform.pluginName !== "offscreen"
    width: 520
    height: 200
    title: "muster · seaqt hello"

    // Nim → QML: re-evaluates whenever the Nim side calls setGreeting (greetingChanged).
    property string seen: backend.greeting

    Text {
        anchors.centerIn: parent
        text: root.seen
        font.pixelSize: 24
    }

    Component.onCompleted: {
        backend.poke(root.seen)        // QML → Nim: a slot with an argument
        backend.answer = "from-qml"    // QML → Nim: a property write through the setter
    }
}
