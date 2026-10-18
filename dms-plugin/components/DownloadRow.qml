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

    // ---- states that need their own words --------------------------------
    //: A magnet still asking peers what it holds: a wait, not a download.
    readonly property bool fetchingDetails: !!dl.isMetadata
    //: Finished, but still uploading to the swarm.
    readonly property bool seeding: !!dl.seeder && status === "active"
    //: aria2 checking the file against its checksum (or a torrent's pieces).
    readonly property bool verifying: !!dl.verifyPending || (dl.verifiedLength > 0 && dl.verifiedLength < (dl.total || 0))
    //: A torrent added held from the Add panel, waiting for its file choice.
    readonly property bool heldForChoice: !!service && service.isHeldForChoice(dl)
    //: Running but nothing arrived yet: "0 B/s, no ETA" would read as a stall.
    readonly property bool connecting: status === "active" && !fetchingDetails && !seeding
                                       && !(dl.completed > 0) && !(dl.downloadSpeed > 0)

    //: The rule closest to firing on this download: {name, left, below} while
    //: its timer runs, or null.
    readonly property var ruleCountdown: {
        let best = null
        for (const name in ruleInfo) {
            const info = ruleInfo[name]
            if (info.acting || !(info.elapsed > 0) || !info.threshold)
                continue
            const left = Math.max(0, info.threshold - info.elapsed)
            if (!best || left < best.left) {
                const rule = service ? service.rules.find(r => r.name === name) : null
                best = {
                    "name": name,
                    "left": left,
                    "elapsed": info.elapsed,
                    "threshold": info.threshold,
                    "below": rule && rule.when ? rule.when.speed_below : null
                }
            }
        }
        return best
    }

    //: Selection is driven by the tab; the row just renders it. While
    //: selecting, rows shrink to a line each: the checkbox, the tile, the
    //: name and where it stands.
    property bool selectable: false
    property bool selected: false
    //: The wide window's list (board 9): one line each — the tile, the name,
    //: where it stands, a thin bar — since the detail opens beside it.
    property bool listMode: false
    readonly property bool compact: selectable || listMode

    //: `range` asks the tab to select everything from the last row clicked.
    signal toggleSelected(bool range)

    function askRemove() {
        if (!finished) {
            service.removeDownload(gid, true, "Cancelled and cleaned up")
            return
        }
        confirmingRemove = true
    }

    readonly property color statusColor: {
        if (heldForChoice)
            return Theme.primary
        if (seeding)
            return Theme.success
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

    //: It downloads through the VPN (the manager lists which do).
    readonly property bool throughVpn: !!service && (service.vpn.routed || []).indexOf(gid) >= 0

    readonly property var badges: {
        const out = []
        if (heldForChoice)
            out.push({
                         "text": "Pick files",
                         "color": Theme.primary
                     })
        else if (seeding)
            out.push({
                         "text": "Seeding",
                         "color": Theme.success
                     })
        else if (fetchingDetails)
            out.push({
                         "text": "Fetching details",
                         "color": Theme.surfaceVariantText
                     })
        // The tile is the status; badges are for extras only.
        if (fileMissing)
            out.push({
                         "text": "File missing",
                         "color": Theme.warning
                     })
        if (dl.isTorrent && !fetchingDetails && !heldForChoice && !seeding)
            out.push({
                         "text": "Torrent",
                         "color": Theme.surfaceVariantText
                     })
        //: A finish action at work on it.
        const job = service ? (service.finishing || []).find(j => j.gid === gid && j.status === "running") : null
        if (job)
            out.push({
                         "text": job.action === "extract" ? "Extracting" : "Running command",
                         "color": Theme.primary
                     })
        //: Downloads through the VPN, beside ones that go direct.
        if (throughVpn)
            out.push({
                         "text": "VPN",
                         "color": Theme.primary
                     })
        //: A rule about to fire counts down, so a pause that is coming is
        //: never a surprise; one already acting says so.
        if (ruleCountdown)
            out.push({
                         "text": ruleCountdown.name + " in " + ruleCountdown.left.toFixed(1) + " s",
                         "color": Theme.warning
                     })
        for (const name in ruleInfo) {
            const info = ruleInfo[name]
            if (info.acting)
                out.push({
                             "text": name + " acting",
                             "color": Theme.warning
                         })
            else if (info.triggers && !(ruleCountdown && ruleCountdown.name === name))
                out.push({
                             "text": name + " ×" + info.triggers,
                             "color": Theme.surfaceVariantText
                         })
        }
        return out
    }

    //: One badge on the line, the rest counted: "+2".
    readonly property var shownBadges: badges.length > 1 ? [badges[0], {
                                                                "text": "+" + (badges.length - 1),
                                                                "color": Theme.surfaceVariantText
                                                            }] : badges

    //: The tile: the kind of file, in the state's colour. Queued and missing
    //: files sit on the plain surface.
    readonly property bool plainTile: status === "waiting" || status === "removed" || fileMissing
    readonly property color tileInk: {
        if (fileMissing)
            return Theme.outline
        return plainTile ? Theme.surfaceVariantText : statusColor
    }
    readonly property color tileFill: plainTile ? Theme.surfaceContainerHigh : Theme.withAlpha(statusColor, 0.15)
    readonly property color barColor: {
        if (fileMissing)
            return Theme.outlineVariant
        return status === "waiting" ? Theme.outline : statusColor
    }

    //: At the end of the name line: how far, or where it stands.
    readonly property string pctText: {
        if (fetchingDetails || heldForChoice)
            return ""
        if (status === "waiting")
            return dl.queuePosition !== undefined && dl.queuePosition !== null ? "#" + (dl.queuePosition + 1) + " in queue" : "Queued"
        if (status === "complete")
            return "Done"
        if (verifying)
            return Math.floor(barFraction * 100) + "%"
        return Math.floor(dl.progress || 0) + "%"
    }

    //: Where it stands in the wide window's one-line rows (board 9).
    readonly property string listText: {
        if (fileMissing)
            return "File missing"
        if (heldForChoice)
            return "Pick files"
        if (fetchingDetails)
            return "Fetching details"
        if (seeding)
            return "Seeding"
        switch (status) {
        case "active":
            return Math.floor(dl.progress || 0) + "%" + (shownSpeed > 0 ? " · " + Fmt.speed(shownSpeed) : "")
        case "waiting":
            return pctText
        case "paused":
            return "Paused · " + Math.floor(dl.progress || 0) + "%"
        case "error": {
            const code = String(dl.errorMessage || "").match(/\b([45]\d\d)\b/)
            return "Failed" + (code ? " · " + code[1] : "")
        }
        case "complete":
            return "Done" + (dl.total > 0 ? " · " + Fmt.bytes(dl.total) : "")
        default:
            return pctText
        }
    }

    //: The host a download is coming from, for "Connecting to …".
    readonly property string host: {
        const m = String(dl.firstUri || "").match(/^[a-z]+:\/\/([^/?#:]+)/i)
        return m ? m[1] : ""
    }

    //: The manager's one speed for it (state.py shown_speed): the same figure
    //: the bar and the speed strip add up.
    readonly property real shownSpeed: dl.speed !== undefined ? dl.speed : (dl.downloadSpeed || 0)

    //: Three facts at most — size, speed, time left. Connections and seeders
    //: are in the detail view. A failure replaces the line with its reason,
    //: and the odd states say what is going on in words.
    readonly property string metaText: {
        if (status === "error" && dl.errorMessage) {
            const known = service ? service.explainError(dl.errorMessage) : null
            return known ? Fmt.label(known.why) + ". " + known.todo : dl.errorMessage
        }
        if (heldForChoice)
            return "Waiting for you — pick files, then start" + (dl.total ? " · " + Fmt.bytes(dl.total) : "")
        if (fetchingDetails)
            return "Asking peers for the file list · " + (dl.connections || 0) + " connected"
        if (seeding) {
            const ratio = dl.total ? (dl.uploaded || 0) / dl.total : 0
            return "↑ " + Fmt.speed(dl.uploadSpeed) + " · ratio " + ratio.toFixed(2) + " · " + (dl.connections || 0) + " peers"
        }
        if (verifying)
            return "Verifying checksum" + (dl.verifyPending ? " · waiting its turn"
                                                            : " · " + Math.floor((dl.verifiedLength || 0) / (dl.total || 1) * 100) + "%")
        if (connecting)
            return host ? "Connecting to " + host + "…" : "Connecting…"
        if (ruleCountdown && ruleCountdown.below)
            return Fmt.speed(shownSpeed) + " — under " + Fmt.speed(ruleCountdown.below) + " for "
                    + ruleCountdown.elapsed.toFixed(1) + " of " + ruleCountdown.threshold + " s"
        const size = dl.total ? Fmt.bytes(dl.total) : ""
        const sofar = dl.total ? Fmt.bytes(dl.completed) + " of " + size : Fmt.bytes(dl.completed)
        const home = Quickshell.env("HOME") || ""
        if (fileMissing)
            return "No longer at " + Fmt.homePath(dl.dir || String(dl.path).replace(/\/[^/]*$/, ""), home)
        switch (status) {
        case "active": {
            const bits = [sofar, Fmt.speed(shownSpeed)]
            if (dl.eta !== null && dl.eta !== undefined && dl.eta >= 0)
                bits.push(Fmt.eta(dl.eta) + " left")
            return bits.join(" · ")
        }
        case "paused":
            return "Paused · " + sofar
        case "waiting":
            return "Waiting for a free slot" + (size ? " · " + size : "")
        case "complete": {
            const bits = [size || Fmt.bytes(dl.completed)]
            if (dl.finishedAt)
                bits.push("finished " + Fmt.ago(dl.finishedAt))
            if (dl.dir)
                bits.push(Fmt.homePath(dl.dir, home))
            return bits.join(" · ")
        }
        default:
            return sofar + (dl.errorMessage ? " · " + dl.errorMessage : "")
        }
    }

    //: The bar's fill: verified bytes while checking, otherwise progress.
    readonly property real barFraction: verifying ? Math.min(1, (dl.verifiedLength || 0) / (dl.total || 1))
                                                  : Math.min(1, (dl.progress || 0) / 100)

    //: The one action that fits the state, shown as a button; the rest are
    //: behind the ⋮ toggle.
    readonly property var primaryAction: {
        if (heldForChoice)
            return {
                "icon": "checklist",
                "text": "Choose files",
                "run": () => {
                    if (!row.expanded)
                        row.toggleExpand()
                }
            }
        if (seeding)
            return {
                "icon": "stop_circle",
                "text": "Stop sharing",
                "run": () => service.post("/api/download/" + gid + "/options", {
                                              "options": {
                                                  "download-only": "true"
                                              }
                                          }, "Stopped sharing")
            }
        if (status === "active")
            return {
                "icon": "pause",
                "text": "Pause",
                "run": () => service.setPaused(gid, true)
            }
        if (status === "paused")
            return {
                "icon": "play_arrow",
                "text": "Resume",
                "run": () => service.setPaused(gid, false)
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
                "run": () => row.openFile()
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


    //: What a double click does: open what is on disk, once there is
    //: something to open — a finished file, or a torrent being shared.
    readonly property bool canOpen: !!dl.path && !fileMissing && (status === "complete" || seeding)

    function openFile() {
        Quickshell.execDetached(["xdg-open", dl.path])
    }

    //: DMS's own application picker, the shell's "Open with".
    function openWith() {
        Quickshell.execDetached(["dms", "open", "--type", "file", dl.path])
    }

    //: Everything else this row can do, labelled. Entries that do not apply
    //: to the state are left out rather than greyed.
    readonly property var moreActions: {
        const out = []
        const queued = status === "waiting" || status === "paused"
        if (status === "waiting")
            out.push({
                         "icon": "pause",
                         "group": "queue",
                         "text": "Pause",
                         "run": () => service.setPaused(gid, true)
                     })
        if (heldForChoice)
            out.push({
                         "icon": "play_arrow",
                         "group": "queue",
                         "text": "Start with every file",
                         "run": () => service.post("/api/download/" + gid + "/resume", null, "Started",
                                                   () => service.releaseHold(gid))
                     })
        if (queued && status !== "waiting")
            out.push({
                         "icon": "vertical_align_top",
                         "group": "queue",
                         "text": "Move to front",
                         "run": () => service.post("/api/download/" + gid + "/position", {
                                                       "pos": 0,
                                                       "how": "POS_SET"
                                                   }, "")
                     })
        if (queued) {
            out.push({
                         "icon": "arrow_upward",
                         "group": "queue",
                         "text": "Move up",
                         "run": () => service.post("/api/download/" + gid + "/position", {
                                                       "pos": -1,
                                                       "how": "POS_CUR"
                                                   }, "")
                     })
            out.push({
                         "icon": "arrow_downward",
                         "group": "queue",
                         "text": "Move down",
                         "run": () => service.post("/api/download/" + gid + "/position", {
                                                       "pos": 1,
                                                       "how": "POS_CUR"
                                                   }, "")
                     })
        }
        // Only meaningful once bytes exist on disk; aria2 reports the final
        // path for finished items and the .part path while running.
        const partial = dl.path && !fileMissing && (status === "active" || status === "paused") && !fetchingDetails
        if (canOpen || partial) {
            out.push({
                         "icon": "open_in_new",
                         "text": canOpen ? "Open" : "Open file",
                         "run": () => openFile()
                     })
            out.push({
                         "icon": "apps",
                         "text": "Open with…",
                         "run": () => openWith()
                     })
        }
        if (dl.dir || dl.path)
            out.push({
                         "icon": "folder_open",
                         "text": "Open folder",
                         "run": () => Quickshell.execDetached(["xdg-open", dl.dir || dl.path.replace(/\/[^/]*$/, "")])
                     })
        if (dl.firstUri)
            out.push({
                         "icon": "link",
                         "text": "Copy link",
                         "run": () => {
                             Quickshell.execDetached(["dms", "cl", "copy", dl.firstUri])
                             service.notice("Link copied")
                         }
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

    height: body.implicitHeight + (listMode ? 22 : (compact ? 18 : 20))
            + (confirmStrip.visible ? confirmStrip.height + 10 : 0)
            + (expanded ? detailLoader.height + 14 + 4 : 0)
    radius: expanded ? 18 : 14
    color: {
        if (selected && !listMode)
            return Theme.withAlpha(Theme.primary, 0.10)
        if ((listMode || selectable) && rowArea.containsMouse && !selected)
            return Theme.surfaceContainerHigh
        return expanded ? Theme.surfaceContainerHigh : Theme.surfaceContainer
    }
    border.width: heldForChoice ? 2 : 1
    border.color: {
        if (heldForChoice)
            return Theme.withAlpha(Theme.primary, 0.7)
        if (confirmingRemove && fileMissing)
            return Theme.withAlpha(Theme.warning, 0.5)
        if (selected)
            return Theme.withAlpha(Theme.primary, 0.7)
        if (status === "error")
            return Theme.withAlpha(Theme.error, 0.4)
        if (selected)
            return Theme.withAlpha(Theme.primary, 0.4)
        return "transparent"
    }

    //: Selecting, a click anywhere on the row ticks it (Shift for a range)
    //: and nothing else happens. Otherwise a click on the card's head opens
    //: or folds its details, as a finished row's does (in the wide list,
    //: picks the download), but not a click inside the details below it;
    //: anywhere, a double click opens it and a right click brings up its
    //: menu at the pointer.
    MouseArea {
        id: rowArea

        readonly property bool overHead: mouseY <= body.y + body.height + 7

        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        hoverEnabled: true
        cursorShape: row.listMode || row.selectable || overHead ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: mouse => {
            if (row.selectable) {
                if (mouse.button === Qt.LeftButton)
                    row.toggleSelected((mouse.modifiers & Qt.ShiftModifier) !== 0)
            } else if (mouse.button === Qt.RightButton) {
                const at = rowArea.mapToItem(rowMenu.parent, mouse.x, mouse.y)
                rowMenu.openAt(at.x, at.y)
            } else if (row.listMode || overHead) {
                row.toggleExpand()
            }
        }
        onDoubleClicked: mouse => {
            if (mouse.button === Qt.LeftButton && row.canOpen && !row.selectable)
                row.openFile()
        }
    }

    Item {
        id: body

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: 10
        anchors.rightMargin: row.compact ? 10 : 8
        anchors.topMargin: row.listMode ? 11 : (row.compact ? 9 : 10)
        implicitHeight: Math.max(row.listMode ? 32 : (row.compact ? 34 : 40), bodyColumn.implicitHeight)

        //: The checkbox reads the click's modifiers, so Shift can select a range.
        Item {
            id: picker

            anchors.left: parent.left
            anchors.verticalCenter: tile.verticalCenter
            visible: row.selectable
            width: visible ? 28 : 0
            height: 28

            DankIcon {
                anchors.centerIn: parent
                name: row.selected ? "check_box" : "check_box_outline_blank"
                size: 20
                color: row.selected ? Theme.primary : Theme.surfaceVariantText
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: mouse => row.toggleSelected((mouse.modifiers & Qt.ShiftModifier) !== 0)
            }
        }

        //: Status at a glance: the kind of file, tinted by state. Also the
        //: handle that opens the detail view.
        Rectangle {
            id: tile

            anchors.left: picker.right
            anchors.leftMargin: row.selectable ? 8 : 0
            anchors.verticalCenter: parent.verticalCenter
            width: row.listMode ? 32 : (row.compact ? 34 : 40)
            height: width
            radius: row.compact ? 10 : 12
            color: row.tileFill

            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                color: row.tileInk
                opacity: tileArea.containsMouse ? 0.10 : 0
            }

            DankIcon {
                anchors.centerIn: parent
                name: Fmt.kindIcon(row.dl.name, row.dl.isTorrent, row.dl.isMetadata)
                size: 20
                color: row.tileInk
            }

            MouseArea {
                id: tileArea

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: mouse => {
                    if (row.selectable)
                        row.toggleSelected((mouse.modifiers & Qt.ShiftModifier) !== 0)
                    else
                        row.toggleExpand()
                }
            }
        }

        //: A finished row whose file is gone needs one click to clear, so the
        //: question shrinks to an inline "Remove entry".
        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: row.confirmingRemove && row.fileMissing
            spacing: 2

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "File already gone ·"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            PillButton {
                anchors.verticalCenter: parent.verticalCenter
                size: 30
                kind: "text"
                text: "Remove entry"
                onClicked: {
                    row.confirmingRemove = false
                    row.service.removeDownload(row.gid, false, "Removed")
                }
            }
        }

        Row {
            id: actions

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: !row.compact && !(row.confirmingRemove && row.fileMissing)
            width: visible ? implicitWidth : 0
            spacing: 4

            //: Pausing and resuming are the everyday ones, so they are filled;
            //: the rest are outlined.
            PillButton {
                anchors.verticalCenter: parent.verticalCenter
                visible: row.primaryAction !== null
                size: 32
                kind: row.heldForChoice ? "filled" : (row.primaryAction && (row.primaryAction.icon === "pause" || row.primaryAction.icon === "play_arrow") ? "tonal" : "outlined")
                icon: row.primaryAction ? row.primaryAction.icon : ""
                text: row.primaryAction ? row.primaryAction.text : ""
                onClicked: row.primaryAction.run()
            }

            //: Unfolded, the row's end button folds it again (board 6).
            DankActionButton {
                id: menuButton

                anchors.verticalCenter: parent.verticalCenter
                buttonSize: 32
                iconSize: 20
                iconName: row.expanded ? "expand_less" : "more_vert"
                iconColor: Theme.surfaceVariantText
                tooltipText: row.expanded ? "Fold" : "More actions"
                onClicked: row.expanded ? row.toggleExpand() : rowMenu.toggle()
            }
        }

        Column {
            id: bodyColumn

            anchors.left: tile.right
            anchors.leftMargin: row.compact ? 10 : 12
            anchors.right: actions.visible ? actions.left : parent.right
            anchors.rightMargin: actions.visible ? 12 : (row.confirmingRemove && row.fileMissing ? 190 : 0)
            anchors.verticalCenter: parent.verticalCenter
            spacing: row.listMode ? 7 : 6

            Item {
                width: parent.width
                height: nameText.implicitHeight

                StyledText {
                    id: nameText

                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, Math.min(implicitWidth, parent.width - (badgeRow.visible ? badgeRow.width : 0)
                                                - (vpnMark.visible ? vpnMark.width + 6 : 0) - pct.implicitWidth - 16))
                    text: row.dl.name || row.gid
                    font.pixelSize: row.compact ? Theme.fontSizeSmall + 1 : Theme.fontSizeMedium
                    font.weight: Font.DemiBold
                    color: Theme.surfaceText
                    wrapMode: Text.NoWrap
                    elide: Text.ElideMiddle

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: mouse => {
                            if (row.selectable)
                                row.toggleSelected((mouse.modifiers & Qt.ShiftModifier) !== 0)
                            else
                                row.toggleExpand()
                        }
                    }
                }

                //: The compact list has no room for badges; through the VPN
                //: still shows, as a small shield after the name.
                DankIcon {
                    id: vpnMark

                    visible: row.compact && row.throughVpn
                    anchors.left: nameText.right
                    anchors.leftMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    name: "shield"
                    size: 14
                    color: Theme.primary
                }

                Row {
                    id: badgeRow

                    visible: !row.compact
                    anchors.left: nameText.right
                    anchors.leftMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4

                    Repeater {
                        model: row.shownBadges

                        Rectangle {
                            id: badge

                            required property var modelData

                            width: badgeLabel.implicitWidth + 14
                            height: 19
                            radius: 6
                            color: badge.modelData.color === Theme.surfaceVariantText ? Theme.surfaceContainerHighest
                                                                                        : Theme.withAlpha(badge.modelData.color, 0.14)

                            StyledText {
                                id: badgeLabel

                                anchors.centerIn: parent
                                text: badge.modelData.text
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.weight: Font.DemiBold
                                color: badge.modelData.color
                            }
                        }
                    }
                }

                StyledText {
                    id: pct

                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.listMode ? row.listText : (row.compact && row.status === "paused" ? "Paused" : row.pctText)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }

            Rectangle {
                id: track

                visible: !row.compact || row.listMode
                width: parent.width
                height: row.listMode ? 3 : 4
                radius: 2
                color: Theme.surfaceContainerHighest
                clip: true

                Rectangle {
                    visible: !row.fetchingDetails
                    width: parent.width * row.barFraction
                    height: parent.height
                    radius: parent.radius
                    color: row.barColor

                    Behavior on width {
                        NumberAnimation {
                            duration: Theme.shortDuration
                            easing.type: Theme.standardEasing
                        }
                    }
                }

                //: Fetching details has no fraction to show: a segment sweeps
                //: across instead, which reads as waiting rather than stuck at 0.
                Rectangle {
                    id: sweep

                    visible: row.fetchingDetails
                    width: parent.width * 0.3
                    height: parent.height
                    radius: parent.radius
                    color: Theme.primary

                    NumberAnimation on x {
                        running: row.fetchingDetails
                        loops: Animation.Infinite
                        from: -sweep.width
                        to: track.width
                        duration: 1400
                        easing.type: Easing.InOutQuad
                    }
                }
            }

            StyledText {
                visible: !row.compact
                width: parent.width
                text: row.metaText
                font.pixelSize: Theme.fontSizeSmall
                color: row.status === "error" ? Theme.error : Theme.surfaceVariantText
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
            }
        }
    }

    // ---- more actions -----------------------------------------------------
    //: Everything else, as a labelled menu off the ⋮ button; the remove
    //: entry sits apart at the bottom.
    MenuPopup {
        id: rowMenu

        readonly property var actionsShown: row.moreActions

        parent: menuButton
        alignEnd: true
        menuWidth: 240
        entries: {
            const out = []
            let group = ""
            for (const a of actionsShown) {
                const g = a.danger ? "danger" : (a.group || "file")
                if (group && g !== group)
                    out.push({
                                 "separator": true
                             })
                group = g
                out.push({
                             "icon": a.icon,
                             "text": a.text,
                             "danger": !!a.danger
                         })
            }
            return out
        }
        onTriggered: index => {
            let n = -1
            for (let i = 0; i <= index; i++) {
                if (!entries[i].separator)
                    n++
            }
            if (!entries[index].separator)
                actionsShown[n].run()
        }
    }

    // ---- remove confirmation --------------------------------------------
    //: Only ever shown for a finished download — see askRemove(). The safe
    //: choice is the primary button. With the file already gone there is
    //: nothing to keep or delete, so the question shrinks to one button.
    Column {
        id: confirmStrip

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: body.bottom
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        anchors.topMargin: 10
        visible: row.confirmingRemove && !row.fileMissing
        height: visible ? implicitHeight : 0
        spacing: 10

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.outlineVariant
        }

        StyledText {
            text: "Remove from the list. Keep the file on disk?"
            font.pixelSize: Theme.fontSizeSmall + 1
            color: Theme.surfaceText
        }

        //: Keeping the file is the safe choice and the primary one.
        Row {
            spacing: 6

            PillButton {
                text: "Keep file"
                size: 30
                kind: "filled"
                onClicked: {
                    row.confirmingRemove = false
                    row.service.removeDownload(row.gid, false, "Removed, file kept")
                }
            }

            PillButton {
                text: "Delete file"
                size: 30
                kind: "dangerFilled"
                onClicked: {
                    row.confirmingRemove = false
                    row.service.removeDownload(row.gid, true, "Removed with its file")
                }
            }

            PillButton {
                text: "Cancel"
                size: 30
                kind: "text"
                onClicked: row.confirmingRemove = false
            }
        }
    }

    Loader {
        id: detailLoader

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: confirmStrip.visible ? confirmStrip.bottom : body.bottom
        anchors.topMargin: 14
        anchors.leftMargin: 14
        anchors.rightMargin: 14
        active: row.expanded
        visible: row.expanded
        height: active && item ? item.implicitHeight : 0

        sourceComponent: Component {
            DetailPanel {
                service: row.service
                gid: row.gid
                dl: row.dl
                held: row.heldForChoice
            }
        }
    }
}
