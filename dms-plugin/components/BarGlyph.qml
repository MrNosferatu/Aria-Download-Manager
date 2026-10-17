import QtQuick
import qs.Common
import qs.Widgets

//: The bar icon: the glyph, an optional progress ring around it, and an
//: optional dot for downloads that finished while nobody was looking. Shared
//: by the horizontal and vertical pills so the two cannot drift apart.
Item {
    id: glyph

    property string iconName: "download"
    property color tint: Theme.surfaceText
    property int size: 20
    //: 0..1 to draw the ring, anything negative to leave it off.
    property real progress: -1
    property bool badge: false
    property bool dim: false

    readonly property bool ringShown: progress >= 0

    implicitWidth: size + (ringShown ? 6 : 0)
    implicitHeight: implicitWidth
    width: implicitWidth
    height: implicitHeight

    Canvas {
        id: ring

        anchors.fill: parent
        visible: glyph.ringShown

        property real value: Math.max(0, Math.min(1, glyph.progress))
        property color tint: glyph.tint
        property color track: Theme.withAlpha(Theme.outline, 0.35)

        onValueChanged: requestPaint()
        onTintChanged: requestPaint()
        onTrackChanged: requestPaint()
        onWidthChanged: requestPaint()
        onVisibleChanged: requestPaint()

        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            const lineWidth = Math.max(2, width / 11)
            const radius = (Math.min(width, height) - lineWidth) / 2
            const cx = width / 2
            const cy = height / 2
            ctx.lineWidth = lineWidth
            ctx.lineCap = "round"
            ctx.strokeStyle = track
            ctx.beginPath()
            ctx.arc(cx, cy, radius, 0, Math.PI * 2)
            ctx.stroke()
            if (value > 0) {
                ctx.strokeStyle = tint
                ctx.beginPath()
                ctx.arc(cx, cy, radius, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * value)
                ctx.stroke()
            }
        }
    }

    DankIcon {
        anchors.centerIn: parent
        name: glyph.iconName
        // Inside the ring the glyph shrinks so the pill keeps its thickness.
        size: glyph.ringShown ? Math.round(glyph.size * 0.62) : glyph.size
        color: glyph.tint
        opacity: glyph.dim ? 0.6 : 1
    }

    Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: glyph.ringShown ? 0 : -1
        anchors.topMargin: glyph.ringShown ? 0 : 1
        width: Math.max(6, Math.round(glyph.size * 0.32))
        height: width
        radius: width / 2
        visible: glyph.badge
        color: Theme.primary
    }
}
