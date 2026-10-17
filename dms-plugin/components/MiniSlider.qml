import QtQuick
import qs.Common

//: Board 12's slider: a thin track filled in the primary colour up to a round
//: thumb. `value` follows the drag; `committed` fires once on release, so a
//: setting is saved once rather than on every pixel. The wheel is left to the
//: page, which scrolls.
Item {
    id: slider

    property int value: 0
    property int minimum: 0
    property int maximum: 100
    property int step: 1

    signal committed(int value)

    readonly property real ratio: maximum > minimum ? (value - minimum) / (maximum - minimum) : 0

    implicitWidth: 180
    implicitHeight: 24

    function valueAt(x) {
        const usable = Math.max(1, width - thumb.width)
        const r = Math.max(0, Math.min(1, (x - thumb.width / 2) / usable))
        const raw = minimum + r * (maximum - minimum)
        return Math.max(minimum, Math.min(maximum, Math.round(raw / step) * step))
    }

    Rectangle {
        id: track

        anchors.verticalCenter: parent.verticalCenter
        x: thumb.width / 2
        width: parent.width - thumb.width
        height: 4
        radius: 2
        color: Theme.outlineVariant

        Rectangle {
            width: parent.width * slider.ratio
            height: parent.height
            radius: 2
            color: Theme.primary
        }
    }

    Rectangle {
        id: thumb

        anchors.verticalCenter: parent.verticalCenter
        x: slider.ratio * (slider.width - width)
        width: area.pressed ? 20 : 18
        height: width
        radius: width / 2
        color: Theme.primary

        Behavior on width {
            NumberAnimation {
                duration: Theme.shortDuration
            }
        }
    }

    MouseArea {
        id: area

        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        preventStealing: true
        onPressed: mouse => slider.value = slider.valueAt(mouse.x)
        onPositionChanged: mouse => {
            if (pressed)
                slider.value = slider.valueAt(mouse.x)
        }
        onReleased: slider.committed(slider.value)
    }
}
