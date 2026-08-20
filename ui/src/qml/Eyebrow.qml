import QtQuick

// Section label — mono, uppercase, tracked, muted (prototype `.eyebrow` /
// `.group-label`). Set `text`. Presentational only.
Text {
    font.family: Theme.typography.mono
    font.pixelSize: Theme.typography.labelSize
    font.capitalization: Font.AllUppercase
    font.letterSpacing: 1.2
    color: Theme.palette.textMuted
}
