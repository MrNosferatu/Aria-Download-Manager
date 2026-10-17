import QtQuick
import qs.Common
import qs.Widgets

//: A bordered text field (board 2): the action's name, its note, a pattern.
FormBox {
    id: field

    property alias text: input.text
    property string placeholderText: ""
    property bool bold: false
    property bool mono: false
    property int alignment: TextInput.AlignLeft

    signal edited(string text)
    signal editingFinished

    focused: input.activeFocus

    function focusInput() {
        input.forceActiveFocus()
    }

    TextInput {
        id: input

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: field.alignment
        color: Theme.surfaceText
        selectionColor: Theme.primarySelected
        selectByMouse: true
        clip: true
        font.pixelSize: field.bold ? Theme.fontSizeMedium + 1 : Theme.fontSizeSmall + 1
        font.weight: field.bold ? Font.Bold : Font.Normal
        font.family: field.mono ? "monospace" : Theme.fontFamily
        onTextEdited: field.edited(text)
        onEditingFinished: field.editingFinished()

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            visible: input.text.length === 0
            horizontalAlignment: field.alignment === TextInput.AlignRight ? Text.AlignRight : Text.AlignLeft
            text: field.placeholderText
            font.pixelSize: input.font.pixelSize
            color: Theme.outline
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        cursorShape: Qt.IBeamCursor
    }
}
