import QtQuick
import qs.Common
import qs.Widgets

//: The Downloads filters. Drawn here rather than with DankFilterChips, which
//: styles every chip alike: an empty filter dims, a non-empty Failed turns
//: error-red so it is noticed, and History — a different list, not a filter
//: on this one — stands apart at the right edge with an outlined look.
Item {
    id: chips

    //: [{label, value, count}], History last.
    property var model: []
    property string current: "all"

    signal picked(string value)

    readonly property var filters: model.filter(c => c.value !== "history")
    readonly property var history: model.find(c => c.value === "history") || null

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
        readonly property bool apart: chipData.value === "history"

        readonly property color ink: {
            if (selected)
                return Theme.onPrimaryContainer
            if (alarm)
                return Theme.error
            if (empty)
                return Theme.outline
            return apart ? Theme.surfaceVariantText : Theme.surfaceText
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
        //: History's outline is dashed, drawn below; the rest are solid.
        border.width: selected || apart ? 0 : 1
        border.color: {
            if (alarm)
                return Theme.withAlpha(Theme.error, 0.5)
            if (empty)
                return Theme.surfaceContainerHighest
            return Theme.outlineVariant
        }

        Canvas {
            id: dashes

            anchors.fill: parent
            visible: chip.apart && !chip.selected

            property color tint: Theme.outlineVariant

            onTintChanged: requestPaint()
            onWidthChanged: requestPaint()

            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                const r = (height - 1) / 2
                ctx.strokeStyle = tint
                ctx.lineWidth = 1
                ctx.setLineDash([3, 3])
                ctx.beginPath()
                ctx.moveTo(r + 0.5, 0.5)
                ctx.lineTo(width - r - 0.5, 0.5)
                ctx.arc(width - r - 0.5, r + 0.5, r, -Math.PI / 2, Math.PI / 2)
                ctx.lineTo(r + 0.5, height - 0.5)
                ctx.arc(r + 0.5, r + 0.5, r, Math.PI / 2, Math.PI * 1.5)
                ctx.stroke()
            }
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
        anchors.right: historyChip.left
        anchors.rightMargin: Theme.spacingS
        spacing: 6

        Repeater {
            model: chips.filters

            Chip {
                required property var modelData

                chipData: modelData
                selected: chips.current === modelData.value
                onActivated: chips.picked(modelData.value)
            }
        }
    }

    Chip {
        id: historyChip

        anchors.right: parent.right
        anchors.top: parent.top
        visible: !!chips.history
        chipData: chips.history || ({})
        selected: chips.current === "history"
        onActivated: chips.picked("history")
    }
}
