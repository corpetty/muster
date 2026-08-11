import QtQuick

// Writes text to the system clipboard. Qt's clipboard is C++-only (QClipboard, Qt
// Gui); QML exposes no clipboard type and this module ships no GUI C++, so the
// write goes through a TextEdit, the one QML-native path. Standalone.
Item {
    id: root

    visible: false

    function copy(text) {
        if (text === "")
            return;
        proxy.text = text;
        proxy.selectAll();
        proxy.copy();
        proxy.text = "";
    }

    TextEdit {
        id: proxy
        visible: false
    }
}
