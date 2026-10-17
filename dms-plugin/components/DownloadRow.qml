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

    //: Running but nothing arrived yet: "0 B/s, no ETA" would read as a stall.
    readonly property bool connecting: status === "active" && !dl.isMetadata
                                       && !(dl.completed > 0) && !(dl.downloadSpeed > 0)

    //: Three facts at most — size, speed, time left. Connections and seeders
    //: are in the detail view. A failure replaces the line with its reason.
    readonly property string metaText: {
        if (status === "error" && dl.errorMessage)
            return dl.errorMessage
        if (connecting)
            return "Connecting…"
        const bits = [(dl.total ? Fmt.bytes(dl.completed) + " of " + Fmt.bytes(dl.total) : Fmt.bytes(dl.completed))
                      + " · " + Math.floor(dl.progress || 0) + "%"]
        if (status === "active") {
            // aria2's own figure is a long average that lags a stall; the
            // measured one is what actually arrived. One number, the truer one.
            const measured = dl.engine === "qbittorrent" ? null : dl.measuredSpeed
            const disagrees = measured !== null && measured !== undefined
                            && Math.abs(measured - dl.downloadSpeed) > Math.max(65536, dl.downloadSpeed * 0.35)
            bits.push(Fmt.speed(disagrees ? measured : dl.downloadSpeed))
            if (dl.eta !== null && dl.eta !== undefined && dl.eta >= 0)
                bits.push(Fmt.eta(dl.eta) + " left")
        }
        if (status === "waiting" && dl.queuePosition !== undefined && dl.queuePosition !== null)
            bits.push("#" + (dl.queuePosition + 1) + " in queue")
        if (fileMissing)
            bits.push("No longer at " + dl.path)
        if (status !== "error" && dl.errorMessage)
            bits.push(dl.errorMessage)
        for (const name in ruleInfo) {
            const info = ruleInfo[name]
            if (info.elapsed > 0 && info.threshold)
                bits.push(name + " " + info.elapsed.toFixed(1) + "/" + info.threshold + "s")
        }
        return bits.join("  ·  ")
    }

    //: The glyph in the status tile: what kind of file it is, so a list of
    //: downloads can be scanned by shape as well as by name.
    readonly property string kindIcon: {
        if (dl.isMetadata || (dl.isTorrent && !dl.name))
            return "hub"
        const name = String(dl.name || "").toLowerCase()
        const ext = (name.match(/\.([a-z0-9]+)$/) || [])[1] || ""
        if (["mkv", "mp4", "webm", "avi", "mov", "m4v", "wmv", "flv", "ts"].indexOf(ext) >= 0)
            return "movie"
        if (["mp3", "flac", "ogg", "opus", "wav", "m4a", "aac"].indexOf(ext) >= 0)
            return "music_note"
        if (["iso", "img", "qcow2", "vdi", "vmdk"].indexOf(ext) >= 0)
            return "album"
        if (["zip", "7z", "rar", "gz", "xz", "zst", "bz2", "tar", "tgz"].indexOf(ext) >= 0)
            return "folder_zip"
        if (["png", "jpg", "jpeg", "gif", "webp", "svg", "avif"].indexOf(ext) >= 0)
            return "image"
        if (["pdf", "epub", "doc", "docx", "odt", "txt", "md"].indexOf(ext) >= 0)
            return "description"
        if (["deb", "rpm", "appimage", "exe", "msi", "pkg", "flatpak"].indexOf(ext) >= 0)
            return "inventory_2"
        return dl.isTorrent ? "hub" : "draft"
    }

    //: The one action that fits the state, shown as a button; the rest are
    //: behind the ⋮ toggle.
    readonly property var primaryAction: {
        if (status === "active")
            return {
                "icon": "pause",
                "text": "Pause",
                "run": () => service.post("/api/download/" + gid + "/pause", null, "")
            }
        if (status === "paused")
            return {
                "icon": "play_arrow",
                "text": "Resume",
                "run": () => service.post("/api/download/" + gid + "/resume", null, "")
            }
        if (status === "waiting")
            return {
                "icon": "vertical_align_top",
                "text": "Start next",
                "run": () => service.post("/api/download/" + gid + "/position", {
                                              "pos": 0,
                                              "how": "POS_SET"
                                          }, "")
            }
        if (status === "complete" && dl.path && !fileMissing)
            return {
                "icon": "open_in_new",
                "text": "Open",
                "run": () => Quickshell.execDetached(["xdg-open", dl.path])
            }
        if (status === "error")
            return {
                "icon": "refresh",
                "text": "Retry",
                "run": () => service.post("/api/download/" + gid + "/retry", null, "Added again")
            }
        if (status === "complete" || status === "removed")
            return {
                "icon": "refresh",
                "text": "Again",
                "run": () => service.post("/api/download/" + gid + "/retry", null, "Added again")
            }
        return null
    }

    property bool showMore: false

    //: Everything else this row can do, labelled. Entries that do not apply
    //: to the state are left out rather than greyed.
    readonly property var moreActions: {
        const out = []
        const queued = status === "waiting" || status === "paused"
        if (status === "waiting")
            out.push({
                         "icon": "pause",
                         "text": "Pause",
                         "run": () => service.post("/api/download/" + gid + "/pause", null, "")
                     })
        if (queued && status !== "waiting")
            out.push({
                         "icon": "vertical_align_top",
                         "text": "Move to front",
                         "run": () => service.post("/api/download/" + gid + "/position", {
                                                       "pos": 0,
                                                       "how": "POS_SET"
                                                   }, "")
                     })
        if (queued) {
            out.push({
                         "icon": "arrow_upward",
                         "text": "Move up",
                         "run": () => service.post("/api/download/" + gid + "/position", {
                                                       "pos": -1,
                                                       "how": "POS_CUR"
                                                   }, "")
                     })
            out.push({
                         "icon": "arrow_downward",
                         "text": "Move down",
                         "run": () => service.post("/api/download/" + gid + "/position", {
                                                       "pos": 1,
                                                       "how": "POS_CUR"
                                                   }, "")
                     })
        }
        // Only meaningful once bytes exist on disk; aria2 reports the final
        // path for finished items and the .part path while running.
        if (dl.path && !fileMissing && (status === "active" || status === "paused"))
            out.push({
                         "icon": "open_in_new",
                         "text": "Open file",
                         "run": () => Quickshell.execDetached(["xdg-open", dl.path])
                     })
        if (dl.dir || dl.path)
            out.push({
                         "icon": "folder_open",
                         "text": "Open folder",
                         "run": () => Quickshell.execDetached(["xdg-open", dl.dir || dl.path.replace(/\/[^/]*$/, "")])
                     })
        if (status === "complete" && dl.path && !fileMissing)
            out.push({
                         "icon": "refresh",
                         "text": "Download again",
                         "run": () => service.post("/api/download/" + gid + "/retry", null, "Added again")
                     })
        out.push({
                     "icon": "info",
                     "text": expanded ? "Hide details" : "Details",
                     "run": () => toggleExpand()
                 })
        // A download still in flight is being *cancelled*; one that has
        // already finished or failed is being thrown away.
        out.push({
                     "icon": live ? "close" : "delete",
                     "text": live ? "Cancel and remove" : "Remove…",
                     "danger": true,
                     "run": () => askRemove()
                 })
        return out
    }

    height: body.implicitHeight + Theme.spacingS * 2
            + (showMore ? moreStrip.height + Theme.spacingS : 0)
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

        //: Status at a glance: the kind of file, tinted by state. Also the
        //: handle that opens the detail view.
        Rectangle {
            id: chevron

            anchors.left: picker.right
            anchors.leftMargin: row.selectable ? Theme.spacingXS : 0
            anchors.top: parent.top
            width: 38
            height: 38
            radius: Theme.cornerRadius
            color: tileArea.containsMouse ? Theme.withAlpha(row.statusColor, 0.26) : Theme.withAlpha(row.statusColor, 0.16)

            DankIcon {
                anchors.centerIn: parent
                name: row.expanded ? "expand_less" : row.kindIcon
                size: 20
                color: row.fileMissing ? Theme.surfaceVariantText : row.statusColor
            }

            MouseArea {
                id: tileArea

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: row.toggleExpand()
            }
        }

        Row {
            id: actions

            anchors.right: parent.right
            anchors.verticalCenter: chevron.verticalCenter
            spacing: Theme.spacingXS

            DankButton {
                anchors.verticalCenter: parent.verticalCenter
                visible: row.primaryAction !== null
                text: row.primaryAction ? row.primaryAction.text : ""
                iconName: row.primaryAction ? row.primaryAction.icon : ""
                buttonHeight: 30
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                onClicked: row.primaryAction.run()
            }

            DankActionButton {
                anchors.verticalCenter: parent.verticalCenter
                buttonSize: 30
                iconSize: Theme.iconSizeSmall
                iconName: row.showMore ? "close" : "more_vert"
                tooltipText: row.showMore ? "Fewer actions" : "More actions"
                onClicked: row.showMore = !row.showMore
            }
        }

        Column {
            id: bodyColumn

            anchors.left: chevron.right
            anchors.leftMargin: Theme.spacingS
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

    // ---- more actions -----------------------------------------------------
    Flow {
        id: moreStrip

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: body.bottom
        anchors.margins: Theme.spacingS
        visible: row.showMore
        height: visible ? implicitHeight : 0
        spacing: Theme.spacingXS

        Repeater {
            model: row.showMore ? row.moreActions : []

            DankButton {
                required property var modelData

                text: modelData.text
                iconName: modelData.icon
                buttonHeight: 30
                backgroundColor: modelData.danger ? Theme.withAlpha(Theme.error, 0.12) : Theme.surfaceContainerHigh
                textColor: modelData.danger ? Theme.error : Theme.surfaceText
                onClicked: {
                    row.showMore = false
                    modelData.run()
                }
            }
        }
    }

    // ---- remove confirmation --------------------------------------------
    // Only ever shown for a finished download — see askRemove().
    Rectangle {
        id: confirmStrip

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: moreStrip.visible ? moreStrip.bottom : body.bottom
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
        anchors.top: confirmStrip.visible ? confirmStrip.bottom : (moreStrip.visible ? moreStrip.bottom : body.bottom)
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
