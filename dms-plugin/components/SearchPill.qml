import QtQuick
import qs.Common
import qs.Widgets

//: The boards' search field: a filled pill with a search glyph, and a clear
//: button once something is typed.
Rectangle {
    id: field

    property alias text: input.text
    property string placeholderText: "Search"
    //: The box's tone; one step darker than whatever card it sits on.
    property color fill: Theme.surfaceContainerHigh
    property int size: 40
    //: Said at the right end while something is typed ("4 found").
    property string trailingText: ""

    implicitHeight: size
    height: size
    radius: height / 2
    color: field.fill
    border.width: input.activeFocus ? 1 : 0
    border.color: Theme.primary

    DankIcon {
        id: glyph

        anchors.left: parent.left
        anchors.leftMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        name: "search"
        size: 18
        color: Theme.surfaceVariantText
    }

    TextInput {
        id: input

        anchors.left: glyph.right
        anchors.leftMargin: 8
        anchors.right: trailing.visible ? trailing.left : (clear.visible ? clear.left : parent.right)
        anchors.rightMargin: clear.visible ? 2 : 14
        anchors.verticalCenter: parent.verticalCenter
        color: Theme.surfaceText
        selectionColor: Theme.primarySelected
        selectByMouse: true
        clip: true
        font.pixelSize: Theme.fontSizeSmall + 1
        font.family: Theme.fontFamily

        Keys.onEscapePressed: event => {
            if (input.text) {
                input.text = ""
                event.accepted = true
            } else {
                event.accepted = false
            }
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            visible: input.text.length === 0
            text: field.placeholderText
            font.pixelSize: Theme.fontSizeSmall + 1
            color: Theme.surfaceVariantText
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            width: parent.width
        }
    }

    StyledText {
        id: trailing

        anchors.right: clear.visible ? clear.left : parent.right
        anchors.rightMargin: clear.visible ? 2 : 14
        anchors.verticalCenter: parent.verticalCenter
        visible: field.trailingText !== "" && input.text.length > 0
        text: field.trailingText
        font.pixelSize: Theme.fontSizeSmall - 1
        color: Theme.surfaceVariantText
    }

    DankActionButton {
        id: clear

        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        visible: input.text.length > 0
        buttonSize: 28
        iconSize: 16
        iconName: "close"
        tooltipText: "Clear"
        onClicked: input.text = ""
    }
}
