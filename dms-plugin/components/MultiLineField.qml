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
    //: Links read best in a fixed-width face.
    property bool mono: false
    //: The links box is sunk below the panel (darker); other boxes are filled.
    property bool sunken: false
    readonly property bool hasFocus: edit.activeFocus

    signal accepted

    implicitHeight: Math.max(minimumHeight, edit.contentHeight + 24)
    radius: root.sunken ? 12 : 10
    color: root.sunken ? Theme.surfaceContainerLowest : Theme.surfaceContainerHigh
    border.width: hasFocus ? 1 : (root.sunken ? 1 : 0)
    border.color: hasFocus ? Theme.primary : Theme.outlineVariant

    TextEdit {
        id: edit

        anchors.fill: parent
        anchors.margins: 12
        color: Theme.surfaceText
        font.pixelSize: root.mono ? Theme.fontSizeSmall : Theme.fontSizeSmall + 1
        font.family: root.mono ? "monospace" : Theme.fontFamily
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
        anchors.margins: 12
        text: root.placeholderText
        color: Theme.outline
        font.pixelSize: Theme.fontSizeSmall
        visible: edit.text.length === 0
        wrapMode: Text.WordWrap
        width: parent.width - 24
    }
}
