import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

//: One line of the right-click quick menu — or, when the entry is a separator,
//: the rule that divides two groups of them.
Item {
    id: row

    //: {icon, text, detail, enabled, danger, action} — or {separator: true}.
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
        anchors.verticalCenter: parent.verticalCenter
        height: 1
        visible: row.isSeparator
        color: Theme.outlineHeavy
    }

    Rectangle {
        id: surface

        readonly property color tint: row.entry.danger && area.containsMouse
                                      && row.usable ? Theme.error : Theme.surfaceText

        anchors.fill: parent
        visible: !row.isSeparator
        radius: Theme.cornerRadius
        opacity: row.usable ? 1 : 0.4
        color: {
            if (!area.containsMouse || !row.usable)
                return "transparent"
            if (row.entry.danger)
                return Theme.errorHover
            return BlurService.hoverColor(Theme.widgetBaseHoverColor)
        }

        DankIcon {
            id: rowIcon

            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            name: row.entry.icon || ""
            size: 16
            color: surface.tint
            opacity: 0.8
        }

        StyledText {
            anchors.left: rowIcon.right
            anchors.leftMargin: Theme.spacingS
            anchors.right: rowDetail.left
            anchors.rightMargin: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter
            text: row.entry.text || ""
            font.pixelSize: Theme.fontSizeSmall
            color: surface.tint
            elide: Text.ElideRight
            wrapMode: Text.NoWrap
        }

        StyledText {
            id: rowDetail

            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            text: row.entry.detail || ""
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
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
