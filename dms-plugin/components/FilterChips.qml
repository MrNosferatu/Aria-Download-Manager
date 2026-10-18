import QtQuick
import qs.Common
import qs.Widgets

//: The Downloads filters. Drawn here rather than with DankFilterChips, which
//: styles every chip alike: an empty filter dims, and a non-empty Failed
//: turns error-red so it is noticed. Finished downloads aria2 forgot are
//: under Done, so there is no separate History.
Item {
    id: chips

    //: [{label, value, count}]
    property var model: []
    property string current: "all"

    signal picked(string value)

    implicitHeight: Math.max(flow.implicitHeight, 32)

    //: Inline components cannot see this file's ids, so the selection comes
    //: in as a property and the click goes out as a signal.
    component Chip: Rectangle {
        id: chip

        property var chipData: ({})
        property bool selected: false

        signal activated
        readonly property bool empty: chipData.count === 0 && chipData.value !== "all"
        readonly property bool alarm: chipData.value === "error" && chipData.count > 0

        readonly property color ink: {
            if (selected)
                return Theme.onPrimaryContainer
            if (alarm)
                return Theme.error
            if (empty)
                return Theme.outline
            return Theme.surfaceText
        }

        width: chipRow.implicitWidth + 24
        height: 32
        radius: height / 2
        color: {
            if (selected)
                return Theme.primaryContainer
            if (alarm)
                return Theme.withAlpha(Theme.error, area.containsMouse ? 0.18 : 0.12)
            return area.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.06) : "transparent"
        }
        border.width: selected ? 0 : 1
        border.color: {
            if (alarm)
                return Theme.withAlpha(Theme.error, 0.5)
            if (empty)
                return Theme.surfaceContainerHighest
            return Theme.outlineVariant
        }


        Row {
            id: chipRow

            anchors.centerIn: parent
            spacing: 6

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: chip.chipData.label || ""
                font.pixelSize: Theme.fontSizeSmall + 1
                font.weight: chip.selected ? Font.DemiBold : Font.Normal
                color: chip.ink
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: chip.chipData.count !== undefined
                text: String(chip.chipData.count)
                font.pixelSize: Theme.fontSizeSmall
                color: chip.selected ? Theme.onPrimaryContainer : (chip.alarm ? Theme.error : (chip.empty ? Theme.outline : Theme.surfaceVariantText))
            }
        }

        MouseArea {
            id: area

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.activated()
        }
    }

    Flow {
        id: flow

        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 6

        Repeater {
            model: chips.model

            Chip {
                required property var modelData

                chipData: modelData
                selected: chips.current === modelData.value
                onActivated: chips.picked(modelData.value)
            }
        }
    }
}
