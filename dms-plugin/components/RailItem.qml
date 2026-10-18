import QtQuick
import qs.Common
import qs.Widgets

//: One entry of the wide window's rail: an icon, a word, and a count or
//: state on the right.
Rectangle {
    id: item

    property string icon: ""
    property string label: ""
    property string count: ""
    property bool selected: false
    //: A count worth noticing (failures): tinted like the Failed chip.
    property bool alarm: false

    signal activated

    width: parent ? parent.width : 0
    height: 38
    radius: Theme.cornerRadius
    color: selected ? Theme.primaryContainer : (area.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.06) : "transparent")

    DankIcon {
        id: glyph

        anchors.left: parent.left
        anchors.leftMargin: Theme.spacingM
        anchors.verticalCenter: parent.verticalCenter
        name: item.icon
        size: 18
        color: item.selected ? Theme.onPrimaryContainer : (item.alarm ? Theme.error : Theme.surfaceVariantText)
    }

    StyledText {
        anchors.left: glyph.right
        anchors.leftMargin: Theme.spacingM
        anchors.right: countText.left
        anchors.rightMargin: Theme.spacingS
        anchors.verticalCenter: parent.verticalCenter
        text: item.label
        font.pixelSize: Theme.fontSizeSmall + 1
        font.weight: item.selected ? Font.DemiBold : Font.Medium
        color: item.selected ? Theme.onPrimaryContainer : Theme.surfaceText
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
    }

    StyledText {
        id: countText

        anchors.right: parent.right
        anchors.rightMargin: Theme.spacingM
        anchors.verticalCenter: parent.verticalCenter
        text: item.count
        font.pixelSize: Theme.fontSizeSmall
        color: item.selected ? Theme.onPrimaryContainer : (item.alarm ? Theme.error : Theme.surfaceVariantText)
    }

    MouseArea {
        id: area

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: item.activated()
    }
}
