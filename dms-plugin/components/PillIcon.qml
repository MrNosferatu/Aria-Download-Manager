import QtQuick
import qs.Common
import qs.Widgets

//: The bar glyph, with what a glance should catch drawn onto it: a thin
//: progress line under the arrow (the browser-download idiom) and a dot when
//: something failed.
Item {
    id: icon

    property string name: "download"
    property int size: Theme.iconSize
    property color color: Theme.surfaceText
    //: 0..1, or below 0 to hide the line (idle, or no size known yet).
    property real progress: -1
    property bool alert: false

    readonly property bool showProgress: progress >= 0
    readonly property int trackHeight: Math.max(2, Math.round(size / 10))

    //: The line hangs just under the glyph's box rather than growing it, so
    //: the icon does not hop when a download starts or ends.
    implicitWidth: size
    implicitHeight: size

    DankIcon {
        anchors.centerIn: parent
        name: icon.name
        size: icon.size
        color: icon.color

        Behavior on color {
            ColorAnimation {
                duration: Theme.shortDuration
            }
        }
    }

    Rectangle {
        id: track

        visible: icon.showProgress
        anchors.top: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.round(icon.size * 0.8)
        height: icon.trackHeight
        radius: height / 2
        color: Theme.withAlpha(icon.color, 0.25)

        Rectangle {
            width: Math.max(track.height, track.width * Math.min(1, Math.max(0, icon.progress)))
            height: parent.height
            radius: parent.radius
            color: icon.color

            Behavior on width {
                NumberAnimation {
                    duration: Theme.shortDuration
                    easing.type: Theme.standardEasing
                }
            }
        }
    }

    Rectangle {
        visible: icon.alert
        width: Math.max(6, Math.round(icon.size / 3.5))
        height: width
        radius: width / 2
        x: icon.size - width + 1
        y: -1
        color: Theme.error
    }
}
