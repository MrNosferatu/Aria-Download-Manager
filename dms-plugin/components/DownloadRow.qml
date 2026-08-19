import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt

Rectangle {
    id: row

    property var service: null
    property string gid: ""
    property var dl: ({})
    property bool expanded: false

    signal toggleExpand

    readonly property string status: dl.status || "unknown"
    readonly property var ruleInfo: service ? service.rulesFor(gid) : ({})

    readonly property color statusColor: {
        switch (status) {
        case "active":
            return Theme.primary
        case "complete":
            return Theme.success
        case "error":
            return Theme.error
        case "paused":
            return Theme.warning
        default:
            return Theme.surfaceVariantText
        }
    }

    readonly property var badges: {
        const out = [
            {
                "text": Fmt.label(status),
                "color": statusColor
            }
        ]
        if (dl.isTorrent)
            out.push({
                         "text": "Torrent",
                         "color": Theme.surfaceVariantText
                     })
        if (dl.seeder)
            out.push({
                         "text": "Seeding",
                         "color": Theme.success
                     })
        for (const name in ruleInfo) {
            const info = ruleInfo[name]
            if (info.acting)
                out.push({
                             "text": name + ": acting",
                             "color": Theme.warning
                         })
            else if (info.triggers)
                out.push({
                             "text": name + " ×" + info.triggers,
                             "color": Theme.surfaceVariantText
                         })
        }
        return out
    }

    readonly property string metaText: {
        const bits = [Fmt.bytes(dl.completed) + " / " + (dl.total ? Fmt.bytes(dl.total) : "?") + " · " + (dl.progress || 0).toFixed(1) + "%"]
        if (status === "active") {
            // aria2's figure is a moving average; the measured one is bytes
            // actually written since the last tick. Showing both when they
            // disagree is what makes a stall visible.
            const measured = dl.measuredSpeed
            const disagrees = measured !== null && measured !== undefined
                            && Math.abs(measured - dl.downloadSpeed) > Math.max(65536, dl.downloadSpeed * 0.35)
            bits.push("↓ " + Fmt.speed(disagrees ? measured : dl.downloadSpeed)
                      + (disagrees ? " (aria2 says " + Fmt.speed(dl.downloadSpeed) + ")" : ""))
            if (dl.isTorrent)
                bits.push("↑ " + Fmt.speed(dl.uploadSpeed))
            bits.push("ETA " + Fmt.eta(dl.eta))
            bits.push((dl.connections || 0) + " conn")
            if (dl.isTorrent)
                bits.push((dl.numSeeders || 0) + " seeders")
        }
        if (status === "waiting" && dl.queuePosition !== undefined && dl.queuePosition !== null)
            bits.push("queue #" + (dl.queuePosition + 1))
        if (dl.errorMessage)
            bits.push(dl.errorMessage)
        for (const name in ruleInfo) {
            const info = ruleInfo[name]
            if (info.elapsed > 0 && info.threshold)
                bits.push(name + " " + info.elapsed.toFixed(1) + "/" + info.threshold + "s")
        }
        return bits.join("  ·  ")
    }

    height: body.implicitHeight + Theme.spacingS * 2 + (expanded ? detailLoader.height + Theme.spacingS : 0)
    radius: Theme.cornerRadius
    color: expanded ? Theme.surfaceContainerHigh : Theme.surfaceContainer
    border.width: 1
    border.color: status === "error" ? Theme.withAlpha(Theme.error, 0.4) : Theme.withAlpha(Theme.outline, 0.12)

    Item {
        id: body

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Theme.spacingS
        implicitHeight: Math.max(38, bodyColumn.implicitHeight)

        DankActionButton {
            id: chevron

            anchors.left: parent.left
            anchors.top: parent.top
            buttonSize: 26
            iconSize: Theme.iconSizeSmall
            iconName: row.expanded ? "expand_more" : "chevron_right"
            tooltipText: "Details"
            onClicked: row.toggleExpand()
        }

        Row {
            id: actions

            anchors.right: parent.right
            anchors.top: parent.top
            spacing: 0

            DankActionButton {
                visible: row.status === "active" || row.status === "waiting"
                buttonSize: 28
                iconSize: Theme.iconSizeSmall
                iconName: "pause"
                tooltipText: "Pause"
                onClicked: row.service.post("/api/download/" + row.gid + "/pause", null, "")
            }

            DankActionButton {
                visible: row.status === "paused"
                buttonSize: 28
                iconSize: Theme.iconSizeSmall
                iconName: "play_arrow"
                tooltipText: "Resume"
                onClicked: row.service.post("/api/download/" + row.gid + "/resume", null, "")
            }

            DankActionButton {
                visible: row.status === "waiting" || row.status === "paused"
                buttonSize: 28
                iconSize: Theme.iconSizeSmall
                iconName: "vertical_align_top"
                tooltipText: "Move to top of queue"
                onClicked: row.service.post("/api/download/" + row.gid + "/position", {
                                                "pos": 0,
                                                "how": "POS_SET"
                                            }, "")
            }

            DankActionButton {
                visible: row.status === "waiting" || row.status === "paused"
                buttonSize: 28
                iconSize: Theme.iconSizeSmall
                iconName: "arrow_upward"
                tooltipText: "Move up"
                onClicked: row.service.post("/api/download/" + row.gid + "/position", {
                                                "pos": -1,
                                                "how": "POS_CUR"
                                            }, "")
            }

            DankActionButton {
                visible: row.status === "waiting" || row.status === "paused"
                buttonSize: 28
                iconSize: Theme.iconSizeSmall
                iconName: "arrow_downward"
                tooltipText: "Move down"
                onClicked: row.service.post("/api/download/" + row.gid + "/position", {
                                                "pos": 1,
                                                "how": "POS_CUR"
                                            }, "")
            }

            DankActionButton {
                // Only meaningful once bytes exist on disk; aria2 reports the
                // final path for finished items and the .part path while running.
                visible: !!row.dl.path && (row.status === "complete" || row.status === "active" || row.status === "paused")
                buttonSize: 28
                iconSize: Theme.iconSizeSmall
                iconName: "open_in_new"
                tooltipText: "Open file"
                onClicked: Quickshell.execDetached(["xdg-open", row.dl.path])
            }

            DankActionButton {
                visible: !!(row.dl.dir || row.dl.path)
                buttonSize: 28
                iconSize: Theme.iconSizeSmall
                iconName: "folder_open"
                tooltipText: "Open containing folder"
                onClicked: {
                    const dir = row.dl.dir || row.dl.path.replace(/\/[^/]*$/, "")
                    Quickshell.execDetached(["xdg-open", dir])
                }
            }

            DankActionButton {
                visible: row.status === "error" || row.status === "complete" || row.status === "removed"
                buttonSize: 28
                iconSize: Theme.iconSizeSmall
                iconName: "refresh"
                tooltipText: "Retry with the same URLs and options"
                onClicked: row.service.post("/api/download/" + row.gid + "/retry", null, "Re-added")
            }

            DankActionButton {
                buttonSize: 28
                iconSize: Theme.iconSizeSmall
                iconName: "close"
                iconColor: Theme.error
                tooltipText: row.status === "active" ? "Stop and remove" : "Remove from list"
                onClicked: row.service.del("/api/download/" + row.gid + "?force=true&purge=true", "")
            }
        }

        Column {
            id: bodyColumn

            anchors.left: chevron.right
            anchors.leftMargin: Theme.spacingXS
            anchors.right: actions.left
            anchors.rightMargin: Theme.spacingS
            anchors.top: parent.top
            spacing: 3

            Row {
                width: parent.width
                spacing: Theme.spacingXS

                StyledText {
                    id: nameText

                    width: Math.max(0, Math.min(implicitWidth, parent.width - badgeRow.width - Theme.spacingXS))
                    text: row.dl.name || row.gid
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    wrapMode: Text.NoWrap
                    elide: Text.ElideMiddle

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: row.toggleExpand()
                    }
                }

                Row {
                    id: badgeRow

                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 3

                    Repeater {
                        model: row.badges

                        Rectangle {
                            id: badge

                            required property var modelData

                            width: badgeLabel.implicitWidth + Theme.spacingS
                            height: 18
                            radius: 5
                            color: Theme.withAlpha(badge.modelData.color, 0.18)

                            StyledText {
                                id: badgeLabel

                                anchors.centerIn: parent
                                text: badge.modelData.text
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                                color: badge.modelData.color
                            }
                        }
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: 4
                radius: 2
                color: Theme.withAlpha(Theme.outline, 0.2)

                Rectangle {
                    width: parent.width * Math.min(1, (row.dl.progress || 0) / 100)
                    height: parent.height
                    radius: parent.radius
                    color: row.statusColor

                    Behavior on width {
                        NumberAnimation {
                            duration: Theme.shortDuration
                            easing.type: Theme.standardEasing
                        }
                    }
                }
            }

            StyledText {
                width: parent.width
                text: row.metaText
                font.pixelSize: Theme.fontSizeSmall
                color: row.dl.errorMessage ? Theme.error : Theme.surfaceVariantText
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
            }
        }
    }

    Loader {
        id: detailLoader

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: body.bottom
        anchors.topMargin: Theme.spacingS
        anchors.leftMargin: Theme.spacingS
        anchors.rightMargin: Theme.spacingS
        active: row.expanded
        visible: row.expanded
        height: active && item ? item.implicitHeight : 0

        sourceComponent: Component {
            DetailPanel {
                service: row.service
                gid: row.gid
                dl: row.dl
            }
        }
    }
}
