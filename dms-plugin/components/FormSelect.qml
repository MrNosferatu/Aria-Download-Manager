import QtQuick
import qs.Common
import qs.Widgets

//: A bordered choice (board 2): the current label and a ▾, opening a menu.
FormBox {
    id: select

    property var labels: []
    property int currentIndex: 0

    signal picked(int index)

    implicitWidth: label.implicitWidth + 12 + 30
    width: implicitWidth
    focused: menu.opened

    StyledText {
        id: label

        anchors.left: parent.left
        anchors.leftMargin: 12
        anchors.right: arrow.left
        anchors.verticalCenter: parent.verticalCenter
        text: select.labels[select.currentIndex] || ""
        font.pixelSize: Theme.fontSizeSmall + 1
        color: Theme.surfaceText
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
    }

    DankIcon {
        id: arrow

        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        name: "arrow_drop_down"
        size: 20
        color: Theme.surfaceVariantText
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: menu.toggle()
    }

    MenuPopup {
        id: menu

        menuWidth: Math.max(select.width, 160)
        entries: select.labels.map((l, i) => ({
                                                 "text": l,
                                                 "checked": i === select.currentIndex
                                             }))
        onTriggered: index => select.picked(index)
    }
}
