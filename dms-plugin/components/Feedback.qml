import QtQuick
import qs.Common
import qs.Widgets

//: The panel's own confirmation pill: "History cleared", "Rules saved".
//: Rises into view with a check, holds for a moment, and sinks away. It lives
//: inside the panel so a success never becomes a shell notification that has
//: to be dismissed. Errors are not shown here; those stay real toasts.
//: Inverse-coloured so it reads over any row, and with Undo when what was
//: done can be reversed (the service hands the undo over with the message).
Rectangle {
    id: pill

    property var service: null
    property string message: ""
    property bool showing: false
    property var undo: null

    readonly property int holdMs: 1800
    //: Long enough to read the message and reach for the button.
    readonly property int undoHoldMs: 5000

    Connections {
        target: pill.service
        function onFeedback(message) {
            pill.message = message
            pill.undo = pill.service.pendingUndo
            pill.showing = true
            hold.restart()
        }
    }

    Timer {
        id: hold

        interval: pill.undo ? pill.undoHoldMs : pill.holdMs
        repeat: false
        onTriggered: pill.showing = false
    }

    width: content.implicitWidth + Theme.spacingL + (undoButton.visible ? Theme.spacingXS : Theme.spacingL)
    height: 36
    radius: height / 2
    color: Theme.inverseSurface
    visible: opacity > 0
    opacity: showing ? 1 : 0
    scale: showing ? 1 : 0.92
    // Rises 8px while fading in, sinks while fading out.
    transform: Translate {
        y: pill.showing ? 0 : 8

        Behavior on y {
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }
    }

    Behavior on opacity {
        NumberAnimation {
            duration: Theme.shortDuration
            easing.type: Theme.standardEasing
        }
    }

    Behavior on scale {
        NumberAnimation {
            duration: Theme.shortDuration
            easing.type: Theme.standardEasing
        }
    }

    //: Click to dismiss early. Under the content, so Undo gets its own click.
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: pill.showing = false
    }

    Row {
        id: content

        anchors.left: parent.left
        anchors.leftMargin: Theme.spacingL
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingS

        DankIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: "check_circle"
            size: Theme.iconSizeSmall
            color: Theme.inverseOnSurface
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: pill.message
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: Theme.inverseOnSurface
        }

        Rectangle {
            id: undoButton

            anchors.verticalCenter: parent.verticalCenter
            visible: !!pill.undo
            width: undoLabel.implicitWidth + Theme.spacingM * 2
            height: 28
            radius: height / 2
            color: undoArea.containsMouse ? Theme.withAlpha(Theme.inversePrimary, 0.16) : "transparent"

            StyledText {
                id: undoLabel

                anchors.centerIn: parent
                text: "Undo"
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Bold
                color: Theme.inversePrimary
            }

            MouseArea {
                id: undoArea

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    const undo = pill.undo
                    pill.undo = null
                    pill.showing = false
                    if (undo)
                        undo.run()
                }
            }
        }
    }
}
