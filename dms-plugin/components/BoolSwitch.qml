import QtQuick
import qs.Common

/* The product's yes/no control, at the size the manager page and the browser
   extension use it (34x20).

   DMS ships DankToggle, and a plugin would normally just use it — but its track
   is a readonly 52x30, which towers over the 40px fields it sits beside in the
   options grid, and it does not match the switch the other two front-ends use.
   Theme colours and DMS's own animation curve keep it native to the shell; only
   the proportions are ours. */
Item {
    id: control

    property bool checked: false
    property bool enabled: true

    signal toggled(bool value)

    implicitWidth: 34
    implicitHeight: 20
    opacity: enabled ? 1 : 0.4

    Rectangle {
        id: track

        anchors.fill: parent
        radius: height / 2
        color: control.checked ? Theme.primary : Theme.surfaceVariant
        border.width: 1
        border.color: control.checked ? Theme.primary : Theme.outline

        Behavior on color {
            ColorAnimation {
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }

        Rectangle {
            id: knob

            width: 14
            height: 14
            radius: 7
            anchors.verticalCenter: parent.verticalCenter
            x: control.checked ? parent.width - width - 2 : 2
            color: control.checked ? Theme.onPrimary : Theme.surfaceVariantText

            Behavior on x {
                NumberAnimation {
                    duration: Theme.shortDuration
                    easing.type: Theme.standardEasing
                }
            }

            Behavior on color {
                ColorAnimation {
                    duration: Theme.shortDuration
                    easing.type: Theme.standardEasing
                }
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        // A 20px-tall control is a small target, so the hit area reaches past it.
        anchors.margins: -6
        enabled: control.enabled
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            control.checked = !control.checked
            control.toggled(control.checked)
        }
    }
}
