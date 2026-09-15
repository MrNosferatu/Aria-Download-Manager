import QtQuick
import qs.Common
import qs.Widgets

/* The product's yes/no control, drawn the way Material 3 draws a switch and at
   the size the manager page and the browser extension use it (44×24): the thumb
   grows and picks up a check when on, so the state reads without colour.

   DMS ships DankToggle, and a plugin would normally just use it, but its track
   is a readonly 52×30, which towers over the 40px fields it sits beside in the
   options grid. Theme colours and DMS's own motion keep this native to the
   shell; only the proportions are ours. */
Item {
    id: control

    property bool checked: false
    property bool enabled: true

    signal toggled(bool value)

    implicitWidth: 44
    implicitHeight: 24
    opacity: enabled ? 1 : 0.38

    Rectangle {
        id: track

        anchors.fill: parent
        radius: height / 2
        color: control.checked ? Theme.primary : Theme.surfaceContainerHighest
        border.width: control.checked ? 0 : 2
        border.color: Theme.outline

        Behavior on color {
            ColorAnimation {
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }

        Rectangle {
            id: knob

            readonly property int size: control.checked ? 18 : 14

            width: size
            height: size
            radius: size / 2
            anchors.verticalCenter: parent.verticalCenter
            x: control.checked ? parent.width - width - 3 : 5
            color: control.checked ? Theme.onPrimary : Theme.outline

            Behavior on x {
                NumberAnimation {
                    duration: Theme.shortDuration
                    easing.type: Theme.standardEasing
                }
            }

            Behavior on width {
                NumberAnimation {
                    duration: Theme.shortDuration
                    easing.type: Theme.standardEasing
                }
            }

            Behavior on height {
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

            DankIcon {
                anchors.centerIn: parent
                name: "check"
                size: 12
                color: Theme.primary
                opacity: control.checked ? 1 : 0
                visible: opacity > 0

                Behavior on opacity {
                    NumberAnimation {
                        duration: Theme.shortDuration
                    }
                }
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        // A 24px-tall control is a small target, so the hit area reaches past it.
        anchors.margins: -6
        enabled: control.enabled
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            control.checked = !control.checked
            control.toggled(control.checked)
        }
    }
}
