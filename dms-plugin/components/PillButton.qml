import QtQuick
import qs.Common
import qs.Widgets

//: The boards' button: a pill with an optional icon. `kind` picks the fill —
//: "filled" (the one primary action of a surface), "tonal" (a raised neutral),
//: "surface" (the field tone, for toolbar pills),
//: "outlined", "text", "danger" (an outlined destructive choice) and
//: "dangerTonal", "dangerFilled" and "dangerText". Coloured from the DMS
//: theme, so it follows the wallpaper.
Item {
    id: button

    property string text: ""
    property string icon: ""
    //: A glyph after the label instead ("Check links →").
    property string trailingIcon: ""
    property string kind: "tonal"
    property int size: 36
    property bool busy: false

    signal clicked

    readonly property bool compact: size <= 32
    readonly property color fill: {
        switch (kind) {
        case "filled":
            return Theme.primary
        case "tonal":
            return Theme.surfaceContainerHighest
        case "surface":
            return Theme.surfaceContainerHigh
        case "dangerTonal":
            return Theme.withAlpha(Theme.error, 0.16)
        case "dangerFilled":
            return Theme.error
        default:
            return "transparent"
        }
    }
    readonly property color ink: {
        switch (kind) {
        case "filled":
            return Theme.onPrimary
        case "dangerFilled":
            return Theme.onError
        case "danger":
        case "dangerText":
        case "dangerTonal":
            return Theme.error
        case "text":
            return Theme.primary
        default:
            return Theme.surfaceText
        }
    }

    implicitWidth: row.implicitWidth + (icon ? (compact ? 8 + 12 : 10 + 16) : (trailingIcon ? (compact ? 12 + 8 : 16 + 10) : (compact ? 24 : 28)))
    implicitHeight: size
    width: implicitWidth
    height: implicitHeight
    opacity: enabled ? 1 : 0.38

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: button.fill
        border.width: button.kind === "outlined" || button.kind === "danger" ? 1 : 0
        border.color: button.kind === "danger" ? Theme.withAlpha(Theme.error, 0.5) : Theme.outlineVariant
    }

    // State layer: hover and press, in the ink's colour.
    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: button.ink
        opacity: area.pressed ? 0.12 : (area.containsMouse ? 0.08 : 0)
    }

    Row {
        id: row

        anchors.verticalCenter: parent.verticalCenter
        //: The icon side has the smaller padding; a button stretched wider
        //: than its content keeps the content centred.
        x: (button.icon ? (button.compact ? 8 : 10) : (button.trailingIcon ? (button.compact ? 12 : 16) : (button.compact ? 12 : 14)))
           + Math.max(0, (button.width - button.implicitWidth) / 2)
        spacing: 4

        DankIcon {
            id: glyph

            anchors.verticalCenter: parent.verticalCenter
            visible: button.icon !== "" || button.busy
            name: button.busy ? "progress_activity" : button.icon
            size: button.compact ? 18 : 20
            color: button.ink

            RotationAnimation on rotation {
                running: button.busy
                loops: Animation.Infinite
                from: 0
                to: 360
                duration: 1000
            }
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            visible: button.text !== ""
            text: button.text
            font.pixelSize: button.compact ? Theme.fontSizeSmall : Theme.fontSizeSmall + 1
            font.weight: button.kind === "filled" || button.kind === "dangerFilled" ? Font.Bold : Font.DemiBold
            color: button.ink
        }

        DankIcon {
            anchors.verticalCenter: parent.verticalCenter
            visible: button.trailingIcon !== ""
            name: button.trailingIcon
            size: button.compact ? 18 : 20
            color: button.ink
        }
    }

    MouseArea {
        id: area

        anchors.fill: parent
        hoverEnabled: true
        enabled: button.enabled && !button.busy
        cursorShape: Qt.PointingHandCursor
        onClicked: button.clicked()
    }
}
