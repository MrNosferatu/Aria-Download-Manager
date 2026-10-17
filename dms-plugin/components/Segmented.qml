import QtQuick
import qs.Common
import qs.Widgets

//: The boards' small segmented control (Simple / Advanced, Hybrid / Disk
//: writes / aria2 reported): a sunken track with the chosen segment raised in
//: the primary container colour.
Rectangle {
    id: seg

    property var model: []
    property int currentIndex: 0
    property int segmentHeight: 28

    signal picked(int index)

    implicitWidth: row.implicitWidth + 6
    implicitHeight: segmentHeight + 6
    width: implicitWidth
    height: implicitHeight
    radius: 10
    color: Theme.surfaceContainerHigh

    Row {
        id: row

        anchors.centerIn: parent
        spacing: 0

        Repeater {
            model: seg.model

            Rectangle {
                id: segment

                required property var modelData
                required property int index

                readonly property bool selected: seg.currentIndex === index

                width: label.implicitWidth + 20
                height: seg.segmentHeight
                radius: 8
                color: selected ? Theme.primaryContainer : (area.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.06) : "transparent")

                StyledText {
                    id: label

                    anchors.centerIn: parent
                    text: segment.modelData
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: segment.selected ? Font.DemiBold : Font.Normal
                    color: segment.selected ? Theme.onPrimaryContainer : Theme.surfaceVariantText
                }

                MouseArea {
                    id: area

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (seg.currentIndex !== segment.index) {
                            seg.currentIndex = segment.index
                            seg.picked(segment.index)
                        }
                    }
                }
            }
        }
    }
}
