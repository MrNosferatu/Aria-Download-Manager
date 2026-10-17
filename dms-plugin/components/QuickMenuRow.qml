import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

//: One line of the right-click quick menu — or, when the entry is a separator,
//: the rule that divides two groups of them.
Item {
    id: row

    //: {icon, text, subtitle, detail, enabled, danger, muted, toggle, action}
    //: — or {separator: true}. `toggle` (a bool) draws a switch in that state;
    //: `muted` greys a row out until it is hovered; `subtitle` is a second,
    //: smaller line under the text (give the row the height for it).
    required property var entry

    property int rowHeight: 34
    property int separatorHeight: Theme.spacingS * 2 + 1

    readonly property bool isSeparator: entry.separator === true
    readonly property bool usable: !isSeparator && entry.enabled !== false

    signal triggered

    height: isSeparator ? separatorHeight : rowHeight

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 6
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        height: 1
        visible: row.isSeparator
        color: Theme.outlineVariant
    }

    Rectangle {
        id: surface

        readonly property color tint: {
            if (row.entry.danger && area.containsMouse && row.usable)
                return Theme.error
            if (row.entry.muted)
                return Theme.surfaceVariantText
            return Theme.surfaceText
        }

        anchors.fill: parent
        visible: !row.isSeparator
        radius: 10
        opacity: row.usable ? 1 : 0.4
        //: `highlight` raises a row onto the surface tone (the clipboard row
        //: when it leads the menu).
        color: {
            if (area.containsMouse && row.usable)
                return row.entry.danger ? Theme.withAlpha(Theme.error, 0.12) : Theme.withAlpha(Theme.surfaceText, 0.08)
            return row.entry.highlight ? Theme.surfaceContainerHigh : "transparent"
        }

        DankIcon {
            id: rowIcon

            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            name: row.entry.icon || ""
            size: row.entry.highlight ? 20 : 18
            color: row.entry.highlight ? Theme.primary : surface.tint
        }

        Column {
            anchors.left: rowIcon.right
            anchors.leftMargin: 10
            anchors.right: rowDetail.left
            anchors.rightMargin: row.entry.toggle !== undefined ? 48 : 4
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            StyledText {
                width: parent.width
                text: row.entry.text || ""
                font.pixelSize: Theme.fontSizeSmall + 1
                color: surface.tint
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
            }

            StyledText {
                width: parent.width
                visible: !!row.entry.subtitle
                text: row.entry.subtitle || ""
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
                elide: Text.ElideMiddle
                wrapMode: Text.NoWrap
            }
        }

        StyledText {
            id: rowDetail

            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            text: row.entry.detail || ""
            visible: row.entry.toggle === undefined
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
        }

        // Drawn rather than a BoolSwitch: the whole row is the click target.
        Rectangle {
            id: rowSwitch

            readonly property bool on: row.entry.toggle === true

            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            visible: row.entry.toggle !== undefined
            width: 38
            height: 22
            radius: 11
            color: on ? Theme.primary : "transparent"
            border.width: on ? 0 : 2
            border.color: Theme.outline

            Rectangle {
                x: rowSwitch.on ? parent.width - width - 3 : 4
                anchors.verticalCenter: parent.verticalCenter
                width: rowSwitch.on ? 16 : 12
                height: width
                radius: width / 2
                color: rowSwitch.on ? Theme.onPrimary : Theme.outline

                Behavior on x {
                    NumberAnimation {
                        duration: Theme.shortDuration
                        easing.type: Theme.standardEasing
                    }
                }
            }
        }

        MouseArea {
            id: area

            anchors.fill: parent
            hoverEnabled: true
            enabled: row.usable
            cursorShape: Qt.PointingHandCursor
            onClicked: row.triggered()
        }
    }
}
