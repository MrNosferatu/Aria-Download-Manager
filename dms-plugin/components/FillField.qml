import QtQuick
import qs.Common
import qs.Widgets

//: The boards' form field: a filled, softly rounded box (no outline until it
//: has focus), an optional leading glyph and trailing unit.
Rectangle {
    id: field

    property alias text: input.text
    property alias validator: input.validator
    property alias inputActive: input.activeFocus
    property string placeholderText: ""
    property string icon: ""
    property string suffix: ""
    //: Shown in front of the value once there is one ("Referer: debian.org"),
    //: so a filled-in form still says which field is which.
    property string label: ""
    readonly property bool filled: input.text.trim().length > 0
    property bool mono: false
    //: The box's tone; one step darker than whatever card it sits on.
    property color fill: Theme.surfaceContainerHigh
    property int size: 36
    property int alignment: TextInput.AlignLeft

    signal editingFinished
    signal accepted

    function focusInput() {
        input.forceActiveFocus()
    }

    implicitHeight: size
    height: size
    radius: 10
    color: field.fill
    border.width: input.activeFocus ? 1 : 0
    border.color: Theme.primary

    DankIcon {
        id: glyph

        anchors.left: parent.left
        anchors.leftMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        visible: field.icon !== ""
        name: field.icon
        size: 18
        color: Theme.surfaceVariantText
    }

    StyledText {
        id: prefix

        anchors.left: glyph.visible ? glyph.right : parent.left
        anchors.leftMargin: glyph.visible ? 8 : 10
        anchors.verticalCenter: parent.verticalCenter
        visible: field.label !== "" && field.filled
        text: field.label + ":"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    TextInput {
        id: input

        anchors.left: prefix.visible ? prefix.right : (glyph.visible ? glyph.right : parent.left)
        anchors.leftMargin: prefix.visible ? 5 : (glyph.visible ? 8 : 10)
        anchors.right: unit.visible ? unit.left : parent.right
        anchors.rightMargin: unit.visible ? 6 : 10
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: field.alignment
        color: Theme.surfaceText
        selectionColor: Theme.primarySelected
        selectByMouse: true
        clip: true
        font.pixelSize: Theme.fontSizeSmall
        font.family: field.mono ? "monospace" : Theme.fontFamily
        onEditingFinished: field.editingFinished()
        onAccepted: field.accepted()

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            visible: input.text.length === 0
            horizontalAlignment: field.alignment === TextInput.AlignRight ? Text.AlignRight : Text.AlignLeft
            text: field.placeholderText
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.outline
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
        }
    }

    StyledText {
        id: unit

        anchors.right: parent.right
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        visible: field.suffix !== "" && field.filled
        text: field.suffix
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        cursorShape: Qt.IBeamCursor
    }
}
