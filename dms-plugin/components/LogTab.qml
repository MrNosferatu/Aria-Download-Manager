import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt

Item {
    id: tab

    property var service: null

    //: Embedded under a section header that already names the log and counts
    //: its entries, so the tab's own title would just say it twice.
    property bool compact: false

    function levelColor(level) {
        switch (level) {
        case "error":
            return Theme.error
        case "warn":
        case "warning":
            return Theme.warning
        case "rule":
            return Theme.primary
        default:
            return Theme.surfaceVariantText
        }
    }

    Item {
        id: header

        width: parent.width
        height: tab.compact ? 36 : 40

        StyledText {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: !tab.compact
            text: "Event log · " + (tab.service ? tab.service.events.length : 0)
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingS

            DankButton {
                text: "Reload"
                iconName: "refresh"
                buttonHeight: 40
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                onClicked: tab.service.loadLog()
            }

            DankButton {
                text: "Clear view"
                iconName: "clear_all"
                buttonHeight: 40
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                onClicked: tab.service.events = []
            }
        }
    }

    DankListView {
        id: list

        anchors.top: header.bottom
        anchors.topMargin: Theme.spacingXS
        anchors.bottom: parent.bottom
        width: parent.width
        clip: true
        spacing: 1
        model: tab.service ? tab.service.events : []

        delegate: Row {
            id: line

            required property var modelData

            width: list.width
            height: 22
            spacing: Theme.spacingS

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: 56
                text: Fmt.time(line.modelData.ts)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: 40
                text: Fmt.label(line.modelData.level)
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: tab.levelColor(line.modelData.level)
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, parent.width - 56 - 40 - Theme.spacingS * 2)
                text: String(line.modelData.message || "").replace(/\s+/g, " ")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                wrapMode: Text.NoWrap
                elide: Text.ElideRight

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        Quickshell.execDetached(["dms", "cl", "copy", line.modelData.message])
                        tab.service.notice("Copied")
                    }
                }
            }
        }
    }

    StyledText {
        anchors.centerIn: parent
        visible: list.count === 0
        text: "Nothing logged yet."
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
    }
}
