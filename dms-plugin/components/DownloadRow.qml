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

    //: The manager stats a finished download's file every tick. Undefined means
    //: it had no reason to look (still running, or no path), which is not the
    //: same as "gone" — only an explicit false means the file moved or was
    //: deleted.
    readonly property bool fileMissing: dl.fileExists === false

    //: Only a *finished* download poses a question worth asking: its file is
    //: the whole point, so removing the row and deleting the file are two
    //: different intentions. A download that never finished leaves nothing but
    //: a half-written part file, so cancelling it just takes that with it.
    property bool confirmingRemove: false

    readonly property bool finished: status === "complete"

    //: Still in flight — cancelling it is a different act from deleting a
    //: download that has already stopped, and the icons say so.
    readonly property bool live: status === "active" || status === "waiting" || status === "paused"

    //: Selection is driven by the tab; the row just renders it.
    property bool selectable: false
    property bool selected: false

    signal toggleSelected

    function askRemove() {
        if (!finished) {
            service.removeDownload(gid, true, "Cancelled and cleaned up")
            return
        }
        confirmingRemove = true
    }

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
                "text": Fmt.statusLabel(status),
                "color": statusColor
            }
        ]
        if (fileMissing)
            out.push({
                         "text": "File missing",
                         "color": Theme.warning
                     })
        //: The metadata fetch goes away by itself once the torrent it
        //: describes starts, so it reads as the wait, not as a download.
        if (dl.isMetadata)
            out.push({
                         "text": "Fetching details",
                         "color": Theme.surfaceVariantText
                     })
        else if (dl.isTorrent)
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
                             "text": name + " acting",
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
        const bits = [Fmt.bytes(dl.completed) + " of " + (dl.total ? Fmt.bytes(dl.total) : "?") + " · " + (dl.progress || 0).toFixed(1) + "%"]
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
            bits.push(Fmt.eta(dl.eta) + " left")
            bits.push((dl.connections || 0) + " connection" + (dl.connections === 1 ? "" : "s"))
            if (dl.isTorrent)
                bits.push((dl.numSeeders || 0) + " seeders")
        }
        if (status === "waiting" && dl.queuePosition !== undefined && dl.queuePosition !== null)
            bits.push("#" + (dl.queuePosition + 1) + " in queue")
        if (fileMissing)
            bits.push("No longer at " + dl.path)
        if (dl.errorMessage)
            bits.push(dl.errorMessage)
        for (const name in ruleInfo) {
            const info = ruleInfo[name]
            if (info.elapsed > 0 && info.threshold)
                bits.push(name + " " + info.elapsed.toFixed(1) + "/" + info.threshold + "s")
        }
        return bits.join("  ·  ")
    }

    height: body.implicitHeight + Theme.spacingS * 2
            + (confirmingRemove ? confirmStrip.height + Theme.spacingS : 0)
            + (expanded ? detailLoader.height + Theme.spacingS : 0)
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
            id: picker

            anchors.left: parent.left
            anchors.top: parent.top
            visible: row.selectable
            width: visible ? 26 : 0
            buttonSize: 26
            iconSize: Theme.iconSizeSmall
            iconName: row.selected ? "check_box" : "check_box_outline_blank"
            iconColor: row.selected ? Theme.primary : Theme.surfaceVariantText
            tooltipText: row.selected ? "Deselect" : "Select"
            onClicked: row.toggleSelected()
        }

        DankActionButton {
            id: chevron

            anchors.left: picker.right
            anchors.leftMargin: row.selectable ? Theme.spacingXXS : 0
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
                tooltipText: "Move to the front of the queue"
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
                visible: !!row.dl.path && !row.fileMissing
                         && (row.status === "complete" || row.status === "active" || row.status === "paused")
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
                tooltipText: "Open folder"
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
                tooltipText: "Download again with the same links and options"
                onClicked: row.service.post("/api/download/" + row.gid + "/retry", null, "Added again")
            }

            DankActionButton {
                buttonSize: 28
                iconSize: Theme.iconSizeSmall
                // A download still in flight is being *cancelled*, which is what
                // a cross means; one that has already finished or failed is
                // being thrown away, which is what the bin means.
                iconName: row.live ? "close" : "delete"
                iconColor: Theme.error
                tooltipText: row.live ? "Cancel and remove" : "Remove…"
                onClicked: row.askRemove()
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

    // ---- remove confirmation --------------------------------------------
    // Only ever shown for a finished download — see askRemove().
    Rectangle {
        id: confirmStrip

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: body.bottom
        anchors.margins: Theme.spacingS
        visible: row.confirmingRemove
        height: visible ? 40 : 0
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Theme.error, 0.10)
        border.width: 1
        border.color: Theme.withAlpha(Theme.error, 0.35)

        StyledText {
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingS
            anchors.right: confirmButtons.left
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            text: row.fileMissing ? "The file is already gone. Remove this entry?"
                                  : "Remove this download. Keep the file, or delete it too?"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceText
            elide: Text.ElideRight
        }

        Row {
            id: confirmButtons

            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS

            DankButton {
                text: "Cancel"
                buttonHeight: 28
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                onClicked: row.confirmingRemove = false
            }

            DankButton {
                text: "Keep file"
                buttonHeight: 28
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                onClicked: {
                    row.confirmingRemove = false
                    row.service.removeDownload(row.gid, false, "Removed, file kept")
                }
            }

            DankButton {
                text: "Delete file"
                buttonHeight: 28
                enabled: !row.fileMissing
                opacity: enabled ? 1 : 0.4
                backgroundColor: Theme.error
                textColor: Theme.onPrimary
                onClicked: {
                    row.confirmingRemove = false
                    row.service.removeDownload(row.gid, true, "Removed with its file")
                }
            }
        }
    }

    Loader {
        id: detailLoader

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: confirmStrip.visible ? confirmStrip.bottom : body.bottom
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
