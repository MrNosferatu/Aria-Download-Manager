import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Widgets

// Multi-line text input styled like DankTextField, which is single-line only.
Rectangle {
    id: root

    property alias text: edit.text
    property string placeholderText: ""
    property int minimumHeight: 64
    readonly property bool hasFocus: edit.activeFocus

    signal accepted

    implicitHeight: Math.max(minimumHeight, edit.contentHeight + Theme.spacingM * 2)
    radius: Theme.cornerRadius
    color: Theme.surfaceContainerHigh
    border.width: hasFocus ? 2 : 1
    border.color: hasFocus ? Theme.primary : Theme.withAlpha(Theme.outline, 0.25)

    TextEdit {
        id: edit

        anchors.fill: parent
        anchors.margins: Theme.spacingM
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeMedium
        font.family: Theme.fontFamily
        selectByMouse: true
        selectionColor: Theme.primarySelected
        wrapMode: TextEdit.Wrap

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return && (event.modifiers & Qt.ControlModifier)) {
                root.accepted()
                event.accepted = true
            }
        }
    }

    StyledText {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: Theme.spacingM
        text: root.placeholderText
        color: Theme.outlineButton
        font.pixelSize: Theme.fontSizeMedium
        visible: edit.text.length === 0
        wrapMode: Text.WordWrap
        width: parent.width - Theme.spacingM * 2
    }
}
