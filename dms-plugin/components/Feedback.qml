import QtQuick
import qs.Common
import qs.Widgets

//: The panel's own confirmation pill: "History cleared", "Rules saved".
//: Rises into view with a check, holds for a moment, and sinks away. It lives
//: inside the panel so a success never becomes a shell notification that has
//: to be dismissed. Errors are not shown here; those stay real toasts.
Rectangle {
    id: pill

    property var service: null
    property string message: ""
    property bool showing: false

    readonly property int holdMs: 1800

    Connections {
        target: pill.service
        function onFeedback(message) {
            pill.message = message
            pill.showing = true
            hold.restart()
        }
    }

    Timer {
        id: hold

        interval: pill.holdMs
        repeat: false
        onTriggered: pill.showing = false
    }

    width: content.implicitWidth + Theme.spacingL * 2
    height: 36
    radius: height / 2
    color: Theme.primary
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

    Row {
        id: content

        anchors.centerIn: parent
        spacing: Theme.spacingS

        DankIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: "check_circle"
            size: Theme.iconSizeSmall
            color: Theme.onPrimary
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: pill.message
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: Theme.onPrimary
        }
    }

    //: Click to dismiss early.
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: pill.showing = false
    }
}
