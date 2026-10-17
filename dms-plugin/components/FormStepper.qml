import QtQuick
import qs.Common
import qs.Widgets

//: − value + in one bordered box (board 2), for seconds, counts and percents.
//: The number can be typed as well; `value` is a string so a half-typed one
//: is shown as typed, and marked when it is not a number at or over the
//: minimum.
FormBox {
    id: stepper

    property string value: ""
    property real step: 1
    property real minimum: 0
    //: 0 for no upper bound.
    property real maximum: 0

    signal edited(string value)

    readonly property bool valid: value !== "" && isFinite(Number(value)) && Number(value) >= minimum
                                  && (maximum <= 0 || Number(value) <= maximum)

    function bump(by) {
        let next = (isFinite(Number(value)) && value !== "" ? Number(value) : minimum) + by
        next = Math.max(minimum, next)
        if (maximum > 0)
            next = Math.min(maximum, next)
        // Keep halves as halves, not 1.5000000000000002.
        next = Math.round(next * 100) / 100
        stepper.edited(String(next))
    }

    implicitWidth: 112
    width: implicitWidth
    invalid: !valid
    focused: input.activeFocus

    //: Typing breaks the text's binding; − and + still have to show. A value
    //: that only tidies what is being typed ("1." → 1) leaves the text alone.
    onValueChanged: {
        if (!input.activeFocus || Number(input.text) !== Number(value) || input.text.trim() === "")
            input.text = value
    }

    component Step: Rectangle {
        id: stepButton

        property string icon: ""
        signal pressed

        width: 34
        height: parent.height
        radius: 9
        color: stepArea.containsMouse ? Theme.surfaceContainerHighest : "transparent"

        DankIcon {
            anchors.centerIn: parent
            name: stepButton.icon
            size: 18
            color: Theme.surfaceVariantText
        }

        MouseArea {
            id: stepArea

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: stepButton.pressed()
        }
    }

    Step {
        anchors.left: parent.left
        icon: "remove"
        onPressed: stepper.bump(-stepper.step)
    }

    TextInput {
        id: input

        anchors.centerIn: parent
        width: parent.width - 68
        horizontalAlignment: TextInput.AlignHCenter
        text: stepper.value
        color: stepper.invalid ? Theme.error : Theme.surfaceText
        selectionColor: Theme.primarySelected
        selectByMouse: true
        clip: true
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.DemiBold
        onTextEdited: stepper.edited(text.trim())
    }

    Step {
        anchors.right: parent.right
        icon: "add"
        onPressed: stepper.bump(stepper.step)
    }
}
