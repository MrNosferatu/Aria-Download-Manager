import QtQuick
import qs.Common
import qs.Widgets

//: A small count as − 8 + on one filled box (boards 6 and 8). The number can
//: be typed as well; `value` is a string so an unset option stays "".
Rectangle {
    id: stepper

    property string value: ""
    property int minimum: 1
    //: 0 for no upper bound.
    property int maximum: 0
    property string placeholder: "—"
    //: The box's tone; one step darker than whatever card it sits on.
    property color fill: Theme.surfaceContainerHigh

    signal edited(string value)

    readonly property int current: parseInt(value) || 0

    function step(by) {
        let next = (value === "" ? minimum : current) + by
        next = Math.max(minimum, next)
        if (maximum > 0)
            next = Math.min(maximum, next)
        stepper.value = String(next)
        stepper.edited(stepper.value)
    }

    implicitWidth: 96
    implicitHeight: 36
    width: implicitWidth
    height: implicitHeight
    radius: 10
    color: stepper.fill

    DankActionButton {
        anchors.left: parent.left
        anchors.leftMargin: 2
        anchors.verticalCenter: parent.verticalCenter
        buttonSize: 30
        iconSize: 16
        iconName: "remove"
        iconColor: Theme.surfaceText
        tooltipText: "Fewer"
        enabled: stepper.value === "" || stepper.current > stepper.minimum
        opacity: enabled ? 1 : 0.38
        onClicked: stepper.step(-1)
    }

    TextInput {
        id: input

        anchors.centerIn: parent
        width: parent.width - 64
        horizontalAlignment: TextInput.AlignHCenter
        text: stepper.value
        color: Theme.surfaceText
        selectByMouse: true
        font.pixelSize: Theme.fontSizeSmall + 1
        font.family: Theme.fontFamily
        validator: IntValidator {
            bottom: 0
        }
        onTextEdited: {
            stepper.value = text.trim()
            stepper.edited(stepper.value)
        }

        StyledText {
            anchors.centerIn: parent
            visible: input.text.length === 0
            text: stepper.placeholder
            font.pixelSize: Theme.fontSizeSmall + 1
            color: Theme.outline
        }
    }

    DankActionButton {
        anchors.right: parent.right
        anchors.rightMargin: 2
        anchors.verticalCenter: parent.verticalCenter
        buttonSize: 30
        iconSize: 16
        iconName: "add"
        iconColor: Theme.surfaceText
        tooltipText: "More"
        enabled: stepper.maximum === 0 || stepper.current < stepper.maximum
        opacity: enabled ? 1 : 0.38
        onClicked: stepper.step(1)
    }
}
