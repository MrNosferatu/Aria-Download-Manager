import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt

Rectangle {
    id: row

    property var service: null
    property var entry: ({})

    readonly property color statusColor: entry.status === "complete" ? Theme.success
                                       : (entry.status === "error" ? Theme.error : Theme.surfaceVariantText)

    //: The manager stats each recorded path when it serves the history. Only an
    //: explicit false means the file has since been moved or deleted; undefined
    //: means the row never had a path to check.
    readonly property bool fileMissing: entry.file_exists === false

    height: 54
    radius: Theme.cornerRadius
    color: Theme.surfaceContainer
    border.width: 1
    border.color: Theme.withAlpha(Theme.outline, 0.12)

    Column {
        anchors.left: parent.left
        anchors.right: actions.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.spacingS
        anchors.rightMargin: Theme.spacingS
        spacing: 2

        Row {
            width: parent.width
            spacing: Theme.spacingXS

            StyledText {
                width: Math.max(0, Math.min(implicitWidth, parent.width - statusBadge.width
                                            - (missingBadge.visible ? missingBadge.width + Theme.spacingXS : 0)
                                            - Theme.spacingXS))
                text: row.entry.name || row.entry.key || ""
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceText
                elide: Text.ElideMiddle
            }

            Rectangle {
                id: statusBadge

                anchors.verticalCenter: parent.verticalCenter
                width: statusLabel.implicitWidth + Theme.spacingS
                height: 18
                radius: 5
                color: Theme.withAlpha(row.statusColor, 0.18)

                StyledText {
                    id: statusLabel

                    anchors.centerIn: parent
                    text: Fmt.label(row.entry.status || "")
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: row.statusColor
                }
            }

            Rectangle {
                id: missingBadge

                anchors.verticalCenter: parent.verticalCenter
                visible: row.fileMissing
                width: visible ? missingLabel.implicitWidth + Theme.spacingS : 0
                height: 18
                radius: 5
                color: Theme.withAlpha(Theme.warning, 0.18)

                StyledText {
                    id: missingLabel

                    anchors.centerIn: parent
                    text: "File missing"
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: Theme.warning
                }
            }
        }

        StyledText {
            width: parent.width
            text: {
                const bits = [Fmt.bytes(row.entry.completed)]
                if (row.entry.total && row.entry.total !== row.entry.completed)
                    bits.push("of " + Fmt.bytes(row.entry.total))
                if (row.entry.finished_at)
                    bits.push(Fmt.dateTime(row.entry.finished_at))
                if (row.entry.dir)
                    bits.push(row.entry.dir)
                if (row.fileMissing)
                    bits.push("file is no longer there")
                if (row.entry.error)
                    bits.push(row.entry.error)
                return bits.join("  ·  ")
            }
            font.pixelSize: Theme.fontSizeSmall
            color: row.entry.error ? Theme.error : Theme.surfaceVariantText
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
        }
    }

    Row {
        id: actions

        anchors.right: parent.right
        anchors.rightMargin: Theme.spacingXS
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        DankActionButton {
            visible: !!row.entry.path && !row.fileMissing
            buttonSize: 28
            iconSize: Theme.iconSizeSmall
            iconName: "open_in_new"
            tooltipText: "Open file"
            onClicked: Quickshell.execDetached(["xdg-open", row.entry.path])
        }

        DankActionButton {
            visible: !!(row.entry.dir || row.entry.path)
            buttonSize: 28
            iconSize: Theme.iconSizeSmall
            iconName: "folder_open"
            tooltipText: "Open containing folder"
            onClicked: {
                const dir = row.entry.dir || row.entry.path.replace(/\/[^/]*$/, "")
                Quickshell.execDetached(["xdg-open", dir])
            }
        }

        DankActionButton {
            visible: !!row.entry.url
            buttonSize: 28
            iconSize: Theme.iconSizeSmall
            iconName: "refresh"
            tooltipText: "Download this again"
            onClicked: row.service.post("/api/history/readd", {
                                            "key": row.entry.key
                                        }, "Queued again", () => row.service.loadHistory())
        }

        DankActionButton {
            buttonSize: 28
            iconSize: Theme.iconSizeSmall
            iconName: "delete"
            iconColor: Theme.error
            tooltipText: "Forget this entry"
            onClicked: row.service.post("/api/history/remove", {
                                            "key": row.entry.key
                                        }, "", () => row.service.loadHistory())
        }
    }
}
