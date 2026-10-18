import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt
import "../lib/FileTree.js" as FileTree
import "../lib/Rules.js" as Rules

// A download's details as short tabs instead of one long scroll: Overview
// (the numbers, the piece map, the paths), Files, Peers or Connections, and
// Options. What is wrong, if anything, sits above them all. Every change saves
// as it is made; there is no Apply. While reviewing (the Add panel's held
// torrent) nothing is saved until Start.
Column {
    id: detail

    property var service: null
    //: The tone of tiles, path rows and fields: one step darker than what the
    //: panel sits on (the raised row in the popout, the window's pane).
    property color tileColor: Theme.surfaceContainer
    property string gid: ""
    //: Shown by the Add panel for a torrent held for its file choice: its
    //: choices are kept here and sent together by the Start button.
    property bool reviewing: false
    //: Sent with the options on start while reviewing (the Add panel's folder).
    property var extraOptions: ({})
    //: A torrent the Add panel added held, opened from its row: the file
    //: choice comes first and nothing is transferred until Start.
    property bool held: false

    signal started
    //: Reviewing: the Add panel's Cancel, at the foot of the file list.
    signal cancelRequested

    property var dl: ({})
    property var detailData: null
    property bool optionsInitialized: false

    // ---- tabs --------------------------------------------------------------
    property string section: ""

    readonly property bool multiFile: structureFiles.length > 1
    readonly property var tabs: {
        const out = [{
                         "key": "overview",
                         "label": "Overview"
                     }]
        if (multiFile)
            out.push({
                         "key": "files",
                         "label": "Files · " + structureFiles.length
                     })
        if (isTorrent)
            out.push({
                         "key": "peers",
                         "label": "Peers · " + peers.length
                     })
        else if (hostGroups.length || uris.length > 1)
            out.push({
                         "key": "connections",
                         "label": "Connections · " + servers.length
                     })
        out.push({
                     "key": "options",
                     "label": "Options"
                 })
        return out
    }
    //: A held torrent opens on its files: choosing them is what it waits for.
    readonly property string current: {
        if (tabs.some(t => t.key === section))
            return section
        return (held && multiFile) ? "files" : "overview"
    }

    // ---- files -----------------------------------------------------------
    //: file index -> 0 skip, 1 normal, 2 high, 3 maximum, as chosen here.
    property var levels: ({})
    property double editedAt: 0
    //: The file list's shape, replaced only when it changes, so the 2 s
    //: refresh does not rebuild the rows.
    property var structureFiles: []
    //: file index -> bytes done, refreshed every tick and read by the rows.
    property var progress: ({})
    readonly property var summary: FileTree.treeSummary(structureFiles, levels)

    // ---- options ---------------------------------------------------------
    property bool downloadOnly: false
    property bool sequential: false
    property bool firstLast: false
    property bool showAdvanced: false
    property string savedText: ""
    property var pendingOptions: ({})
    //: The options as they were when the panel opened, and which have been
    //: changed since: what Undo puts back.
    property var initialOptions: ({})
    property var changedOptions: ({})
    readonly property int changeCount: Object.keys(changedOptions).length

    readonly property bool isTorrent: !!statusInfo.bittorrent || !!dl.isTorrent
    //: A torrent run by qBittorrent rather than aria2c.
    readonly property bool isQb: !!(detailData && detailData.engine === "qbittorrent")
    //: The global setting covers every torrent; the panel then just says so.
    readonly property bool downloadOnlyEverywhere: service ? service.downloadOnly : false

    readonly property var statusInfo: (detailData && detailData.status) || ({})
    readonly property var files: (detailData && detailData.files) || []
    readonly property var pieces: (detailData && detailData.pieceMap) || []
    readonly property var uris: (detailData && detailData.uris) || []
    readonly property var peers: {
        const list = ((detailData && detailData.peers) || []).slice()
        return list.sort((a, b) => (Number(b.downloadSpeed) || 0) - (Number(a.downloadSpeed) || 0))
    }
    readonly property var servers: {
        const out = []
        const groups = (detailData && detailData.servers) || []
        for (var i = 0; i < groups.length; i++) {
            const inner = groups[i].servers || []
            for (var j = 0; j < inner.length; j++)
                out.push(inner[j])
        }
        return out
    }

    //: The live connections grouped by host: {host, speed, count, slow}. A
    //: mirror thirty times slower than the best one is marked slow.
    readonly property var hostGroups: {
        const byHost = ({})
        for (const s of servers) {
            const uri = s.currentUri || s.uri || ""
            const m = uri.match(/^[a-z]+:\/\/([^/?#:]+)/i)
            const host = m ? m[1] : uri
            if (!byHost[host])
                byHost[host] = {
                    "host": host,
                    "speed": 0,
                    "count": 0
                }
            byHost[host].speed += Number(s.downloadSpeed) || 0
            byHost[host].count++
        }
        const list = Object.keys(byHost).map(k => byHost[k]).sort((a, b) => b.speed - a.speed)
        const best = list.length ? list[0].speed : 0
        return list.map(g => Object.assign({}, g, {
                                               "slow": list.length > 1 && best > 0 && g.speed * 30 < best
                                           }))
    }

    //: Reused for another download (the Add panel's next torrent): start over.
    onGidChanged: {
        optionsInitialized = false
        detailData = null
        structureFiles = []
        levels = ({})
        editedAt = 0
        fileTreeView.reset()
        changedOptions = ({})
        refresh()
    }

    function shapeOf(list) {
        return list.map(f => f.index + ":" + f.path + ":" + f.length).join("|")
    }

    function refresh() {
        if (!service || !gid)
            return
        service.get("/api/download/" + gid, (payload, error) => {
                        if (error) {
                            detail.detailData = null
                            return
                        }
                        detail.detailData = payload
                        const list = payload.files || []
                        if (detail.shapeOf(list) !== detail.shapeOf(detail.structureFiles))
                            detail.structureFiles = list
                        const done = ({})
                        for (const f of list)
                            done[f.index] = Number(f.completedLength) || 0
                        detail.progress = done
                        // The manager's priorities, unless something was just changed
                        // here: a save in flight must not be undone by the refresh,
                        // nor a choice of no files that aria2 could not take.
                        if (Date.now() - detail.editedAt > 4000 && !detail.unsavedNone) {
                            const server = ({})
                            for (const f of list)
                                server[f.index] = f.priority !== undefined ? f.priority : (f.selected === "true" ? 1 : 0)
                            if (JSON.stringify(server) !== JSON.stringify(detail.levels))
                                detail.levels = server
                        }
                        if (!detail.optionsInitialized) {
                            const opts = payload.options || ({})
                            splitField.value = opts["split"] || ""
                            connField.value = opts["max-connection-per-server"] || ""
                            downField.raw = opts["max-download-limit"] || ""
                            upField.raw = opts["max-upload-limit"] || ""
                            detail.downloadOnly = opts["download-only"] === "true"
                            detail.sequential = opts["sequential-download"] === "true"
                            detail.firstLast = opts["first-last-piece-first"] === "true"
                            if (!detail.changeCount) {
                                const keep = ({})
                                for (const key of ["split", "max-connection-per-server", "max-download-limit", "max-upload-limit",
                                                   "download-only", "sequential-download", "first-last-piece-first"])
                                    keep[key] = opts[key] !== undefined ? String(opts[key]) : ""
                                detail.initialOptions = keep
                            }
                            detail.optionsInitialized = true
                        }
                    })
    }

    //: aria2 needs a file chosen; with none, the choice stays on screen,
    //: unsaved, with a word saying so, rather than snapping back.
    readonly property bool unsavedNone: editedAt > 0 && !isQb && summary.chosen === 0

    function changeLevels(next) {
        levels = next
        editedAt = Date.now()
        if (reviewing)
            return
        savedText = "Saving…"
        levelTimer.restart()
    }

    //: Options save shortly after the last change, so typing a limit is one
    //: request; a switch goes out on the same short timer.
    function queueOption(key, value) {
        if (reviewing || !optionsInitialized)
            return
        const next = Object.assign({}, pendingOptions)
        next[key] = value
        pendingOptions = next
        const changed = Object.assign({}, changedOptions)
        const before = initialOptions[key] || ""
        const same = String(value) === before || (before === "" && (value === "0" || value === "false"))
        if (same)
            delete changed[key]
        else
            changed[key] = true
        changedOptions = changed
        savedText = "Saving…"
        optionTimer.restart()
    }

    //: Put back every option changed since the panel opened.
    function undoOptions() {
        const options = ({})
        for (const key in changedOptions) {
            const before = initialOptions[key] || ""
            const isSwitch = key === "download-only" || key === "sequential-download" || key === "first-last-piece-first"
            options[key] = before !== "" ? before : (isSwitch ? "false" : "0")
        }
        if (!Object.keys(options).length)
            return
        optionTimer.stop()
        pendingOptions = ({})
        service.request("POST", "/api/download/" + gid + "/options", {
                            "options": options
                        }, (data, error) => {
                            if (error) {
                                detail.service.showFailure("Couldn't undo", error)
                                return
                            }
                            detail.changedOptions = ({})
                            detail.savedText = "Undone"
                            // Read the options back into the fields.
                            detail.optionsInitialized = false
                            detail.refresh()
                        })
    }

    function optionsToSend() {
        const options = ({})
        if (detail.isQb) {
            options["sequential-download"] = detail.sequential ? "true" : "false"
            options["first-last-piece-first"] = detail.firstLast ? "true" : "false"
        }
        if (splitField.value && !detail.isQb && !detail.isTorrent)
            options["split"] = splitField.value
        if (connField.value && !detail.isQb)
            options["max-connection-per-server"] = connField.value
        if (downField.value)
            options["max-download-limit"] = downField.value
        const noUpload = detail.isTorrent && (detail.downloadOnly || detail.downloadOnlyEverywhere)
        if (upField.value && !noUpload)
            options["max-upload-limit"] = upField.value
        if (detail.isTorrent && !detail.downloadOnlyEverywhere)
            options["download-only"] = detail.downloadOnly ? "true" : "false"
        Object.assign(options, detail.extraOptions)
        return options
    }

    //: Review: the files, then the options, then go.
    function start() {
        if (summary.chosen === 0) {
            ToastService.showError("Pick at least one file", "A torrent with nothing chosen has nothing to download.")
            return
        }
        const gid = detail.gid
        const resume = () => service.post("/api/download/" + gid + "/resume", null, "Started", () => {
                                              detail.service.releaseHold(gid)
                                              if (detail.dl.following)
                                                  detail.service.releaseHold(detail.dl.following)
                                              detail.started()
                                          })
        const sendOptions = () => {
            const options = detail.reviewing ? detail.optionsToSend() : ({})
            if (Object.keys(options).length === 0)
                resume()
            else
                service.post("/api/download/" + gid + "/options", {
                                 "options": options
                             }, "", resume)
        }
        if (multiFile)
            service.post("/api/download/" + gid + "/files", {
                             "levels": levels
                         }, "", sendOptions)
        else
            sendOptions()
    }

    //: "Start 2 files · 2.8 GB", or plain Start for a single file.
    //: Reviewing (board 5) it counts files; for a held torrent opened from its
    //: row (board 17) it adds the size.
    readonly property string startLabel: {
        if (!multiFile)
            return "Start download"
        const files = "Start " + summary.chosen + (summary.chosen === 1 ? " file" : " files")
        return reviewing ? files : files + " · " + Fmt.bytes(summary.selected)
    }

    //: Count of set bits in aria2's hex bitfield, for a peer's "has".
    function bitsOf(hex) {
        let count = 0
        const text = String(hex || "")
        for (let i = 0; i < text.length; i++) {
            let v = parseInt(text[i], 16)
            while (v) {
                count += v & 1
                v >>= 1
            }
        }
        return count
    }

    function peerHas(p) {
        if (p.progress !== undefined && p.progress !== null)
            return Math.round(Number(p.progress) * 100)
        if (p.seeder === "true")
            return 100
        const pieces = Number(statusInfo.numPieces) || 0
        return pieces ? Math.min(100, Math.round(bitsOf(p.bitfield) / pieces * 100)) : 0
    }

    function copy(label, value) {
        Quickshell.execDetached(["dms", "cl", "copy", String(value)])
        service.notice("Copied " + label.toLowerCase())
    }

    spacing: Theme.spacingS

    Component.onCompleted: refresh()

    Timer {
        interval: 2000
        running: true
        repeat: true
        onTriggered: detail.refresh()
    }

    Timer {
        id: levelTimer

        interval: 500
        onTriggered: {
            if (detail.unsavedNone) {
                detail.savedText = "Pick at least one file"
                return
            }
            detail.service.request("POST", "/api/download/" + detail.gid + "/files", {
                                       "levels": detail.levels
                                   }, (data, error) => {
                                       if (error) {
                                           detail.savedText = ""
                                           detail.service.showFailure("Couldn't save the file choice", error)
                                       } else {
                                           detail.savedText = "Saved"
                                       }
                                   })
        }
    }

    Timer {
        id: optionTimer

        interval: 700
        onTriggered: {
            const options = detail.pendingOptions
            detail.pendingOptions = ({})
            if (Object.keys(options).length === 0)
                return
            detail.service.request("POST", "/api/download/" + detail.gid + "/options", {
                                       "options": options
                                   }, (data, error) => {
                                       if (error) {
                                           detail.savedText = ""
                                           detail.service.showFailure("Couldn't save", error)
                                       } else {
                                           detail.savedText = "Saved"
                                       }
                                   })
        }
    }

    //: Small inline pieces, told their state rather than reading the panel's
    //: (inline components cannot see this file's ids).
    component SectionLabel: StyledText {
        font.pixelSize: Theme.fontSizeSmall
        font.weight: Font.Medium
        color: Theme.surfaceVariantText
    }

    component Dot: Rectangle {
        width: 10
        height: 10
        radius: 3
    }

    // ---- what is wrong, where it cannot be missed -------------------------
    Rectangle {
        width: parent.width
        visible: !!detail.statusInfo.errorMessage
        height: visible ? errorText.implicitHeight + Theme.spacingS * 2 : 0
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Theme.error, 0.12)

        StyledText {
            id: errorText

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingS
            wrapMode: Text.WordWrap
            text: {
                const raw = detail.statusInfo.errorMessage || ""
                const known = detail.service ? detail.service.explainError(raw) : null
                return known ? Fmt.label(known.why) + ". " + known.todo + "\n" + raw : raw
            }
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.error
        }
    }

    // ---- a held torrent says how to go on (board 17) -----------------------
    Column {
        width: parent.width
        visible: detail.held && !detail.reviewing
        spacing: 6

        Row {
            spacing: 8

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "pending_actions"
                size: 20
                color: Theme.primary
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Pick files, then start"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Bold
                color: Theme.surfaceText
            }
        }

        StyledText {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "This torrent was added held so you can choose what to download. Nothing is being transferred yet."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }

    // ---- tabs: underlined, over a hairline ---------------------------------
    Item {
        width: parent.width
        height: 34
        visible: !detail.reviewing && !detail.held

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: Theme.outlineVariant
        }

        Row {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            spacing: 2

            Repeater {
                model: detail.tabs

                Item {
                    id: tabItem

                    required property var modelData

                    readonly property bool selected: detail.current === modelData.key

                    width: tabLabel.implicitWidth + 24
                    height: parent.height

                    Rectangle {
                        anchors.fill: parent
                        anchors.bottomMargin: 2
                        radius: 8
                        color: tabArea.containsMouse && !tabItem.selected ? Theme.withAlpha(Theme.surfaceText, 0.06) : "transparent"
                    }

                    StyledText {
                        id: tabLabel

                        anchors.centerIn: parent
                        anchors.verticalCenterOffset: -1
                        text: tabItem.modelData.label
                        font.pixelSize: Theme.fontSizeSmall + 1
                        font.weight: tabItem.selected ? Font.DemiBold : Font.Normal
                        color: tabItem.selected ? Theme.primary : Theme.surfaceVariantText
                    }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 2
                        radius: 1
                        visible: tabItem.selected
                        color: Theme.primary
                    }

                    MouseArea {
                        id: tabArea

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: detail.section = tabItem.modelData.key
                    }
                }
            }
        }
    }

    // ======== overview =====================================================
    //: The numbers that used to be squeezed into one meta line, a labelled
    //: tile each.
    Grid {
        id: statGrid

        readonly property var stats: {
            const d = detail.dl
            const out = [
                ["Size", d.total ? Fmt.bytes(d.total) : "Unknown"],
                ["Downloaded", Fmt.bytes(d.completed)],
                ["Speed", d.status === "active" ? Fmt.speed(d.downloadSpeed) : "—"],
                ["Time left", d.status === "active" && d.eta !== null && d.eta !== undefined ? Fmt.eta(d.eta) : "—"]
            ]
            if (detail.isTorrent) {
                const ratio = d.total ? (d.uploaded || 0) / d.total : 0
                out.push(["Uploaded", Fmt.bytes(d.uploaded || 0)])
                out.push(["Ratio", ratio.toFixed(2)])
                out.push(["Seeders", String(d.numSeeders || 0)])
                out.push(["Connections", String(d.connections || 0)])
            } else {
                out.push(["Connections", String(d.connections || 0)])
                out.push(["Parts", detail.initialOptions["split"] || "—"])
                out.push(["Added", Fmt.shortWhen(d.addedAt) || "—"])
                out.push(["Finished", Fmt.shortWhen(d.finishedAt) || "—"])
            }
            return out
        }

        width: parent.width
        visible: !detail.reviewing && !detail.held && detail.current === "overview"
        //: Four across in a row; two in the window's narrow detail pane.
        columns: width < 460 ? 2 : 4
        columnSpacing: 8
        rowSpacing: 8

        Repeater {
            model: statGrid.stats

            Rectangle {
                id: statTile

                required property var modelData

                width: (statGrid.width - 8 * (statGrid.columns - 1)) / statGrid.columns
                height: 52
                radius: 10
                color: detail.tileColor

                Column {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 12
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    StyledText {
                        text: statTile.modelData[0]
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        width: parent.width
                        text: statTile.modelData[1]
                        font.pixelSize: Theme.fontSizeMedium + 1
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }

    //: The piece map as a grid of small squares, in three tones that differ
    //: in lightness as well as hue, with a legend.
    Column {
        id: pieceBlock

        readonly property color haveColor: Theme.primary
        readonly property color partColor: Theme.outline
        readonly property color missingColor: Theme.surfaceContainerHighest
        readonly property int cell: 10
        readonly property int gap: 2
        readonly property int columns: Math.max(1, Math.floor((width + gap) / (cell + gap)))
        readonly property int rows: 4
        //: The manager's 256 buckets, resampled to the cells the grid has.
        readonly property var cells: {
            const src = detail.pieces
            const n = columns * rows
            if (!src.length)
                return []
            const out = []
            for (let i = 0; i < n; i++)
                out.push(src[Math.min(src.length - 1, Math.floor(i * src.length / n))])
            return out
        }

        width: parent.width
        visible: !detail.reviewing && !detail.held && detail.current === "overview" && detail.pieces.length > 0
        spacing: 6

        Item {
            width: parent.width
            height: 16

            SectionLabel {
                anchors.left: parent.left
                text: "Pieces · " + (detail.statusInfo.numPieces || 0) + " × " + Fmt.bytes(detail.statusInfo.pieceLength || 0)
            }

            SectionLabel {
                anchors.right: parent.right
                text: Math.floor(detail.dl.progress || 0) + "% have"
            }
        }

        Grid {
            columns: pieceBlock.columns
            spacing: pieceBlock.gap

            Repeater {
                model: pieceBlock.visible ? pieceBlock.cells : []

                Rectangle {
                    required property var modelData

                    width: pieceBlock.cell
                    height: 8
                    radius: 2
                    color: modelData >= 100 ? pieceBlock.haveColor : (modelData > 0 ? pieceBlock.partColor : pieceBlock.missingColor)
                }
            }
        }

        Row {
            spacing: 14

            Repeater {
                model: [["Have", pieceBlock.haveColor], ["Downloading", pieceBlock.partColor], ["Missing", pieceBlock.missingColor]]

                Row {
                    id: legendItem

                    required property var modelData

                    spacing: 5

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 8
                        height: 8
                        radius: 2
                        color: legendItem.modelData[1]
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: legendItem.modelData[0]
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                    }
                }
            }
        }
    }

    //: Where it is and where it came from, each with a copy button.
    Column {
        width: parent.width
        visible: !detail.reviewing && !detail.held && detail.current === "overview"
        spacing: 8

        Repeater {
            model: [
                ["Folder", detail.statusInfo.dir || detail.dl.dir || ""],
                ["Source", detail.dl.firstUri || (detail.files.length === 1 ? (detail.files[0].path || "") : "")]
            ]

            Rectangle {
                id: pathRow

                required property var modelData

                width: detail.width
                visible: String(modelData[1]).length > 0
                height: visible ? 44 : 0
                radius: 10
                color: detail.tileColor

                StyledText {
                    id: pathLabel

                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    width: 54
                    text: pathRow.modelData[0]
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    anchors.left: pathLabel.right
                    anchors.leftMargin: 12
                    anchors.right: copyButton.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: Fmt.homePath(pathRow.modelData[1], Quickshell.env("HOME") || "")
                    wrapMode: Text.NoWrap
                    elide: Text.ElideMiddle
                    font.pixelSize: Theme.fontSizeSmall
                    font.family: "monospace"
                    color: Theme.surfaceText
                }

                DankActionButton {
                    id: copyButton

                    anchors.right: parent.right
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    buttonSize: 30
                    iconSize: 16
                    iconName: "content_copy"
                    iconColor: Theme.surfaceVariantText
                    tooltipText: "Copy the " + pathRow.modelData[0].toLowerCase()
                    onClicked: detail.copy(pathRow.modelData[0], pathRow.modelData[1])
                }
            }
        }
    }

    // ======== files: a tree, like qBittorrent's (boards 5, 17) =============
    //: Shown on the Files tab, while reviewing in the Add panel, and as the
    //: whole panel of a held torrent.
    readonly property bool filesShown: multiFile && (reviewing || held || current === "files")
    FileTreeView {
        id: fileTreeView

        width: parent.width
        visible: detail.filesShown
        files: detail.structureFiles
        base: detail.statusInfo.dir || ""
        levels: detail.levels
        progress: detail.progress
        reviewing: detail.reviewing
        held: detail.held
        tileColor: detail.reviewing ? Theme.surfaceContainerHigh : detail.tileColor
        saving: detail.savedText === "Saving…"
        onLevelsEdited: next => detail.changeLevels(next)
        onOpenRequested: path => Quickshell.execDetached(["xdg-open", path])
    }

    //: A held torrent's choice ends in its two buttons (board 17).
    Row {
        anchors.right: parent.right
        visible: detail.held && !detail.reviewing
        spacing: 8
        topPadding: 6

        PillButton {
            size: 36
            kind: "outlined"
            text: "Remove"
            onClicked: {
                detail.service.releaseHold(detail.gid)
                detail.service.removeDownload(detail.gid, true, "Removed")
            }
        }

        PillButton {
            size: 36
            kind: "filled"
            icon: "play_arrow"
            text: detail.startLabel
            onClicked: detail.start()
        }
    }

    // ======== peers =========================================================
    Column {
        width: parent.width
        visible: !detail.reviewing && detail.current === "peers"
        spacing: 2

        Item {
            width: parent.width
            height: 22

            SectionLabel {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                font.weight: Font.Normal
                text: detail.peers.length + " connected · " + (detail.dl.numSeeders || 0) + " seeders"
            }

            SectionLabel {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                font.weight: Font.Normal
                visible: detail.peers.length > 1
                text: "Sorted by ↓"
            }
        }

        StyledText {
            width: parent.width
            visible: detail.peers.length === 0
            wrapMode: Text.WordWrap
            text: detail.dl.status === "active" ? "No peers connected right now." : "Peers show while the torrent is running."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }

        //: A table: peer, client, down, up, how much it has.
        Row {
            id: peerHeader

            readonly property int clientWidth: 120
            readonly property int speedWidth: 76
            readonly property int hasWidth: 44

            width: parent.width
            height: 30
            visible: detail.peers.length > 0
            spacing: Theme.spacingS

            Repeater {
                model: ["PEER", "CLIENT", "↓", "↑", "HAS"]

                StyledText {
                    required property string modelData
                    required property int index

                    width: [peerHeader.width - peerHeader.clientWidth - peerHeader.speedWidth * 2 - peerHeader.hasWidth - Theme.spacingS * 4,
                            peerHeader.clientWidth, peerHeader.speedWidth, peerHeader.speedWidth, peerHeader.hasWidth][index]
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: index >= 2 ? Text.AlignRight : Text.AlignLeft
                    text: modelData
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.5
                    color: Theme.outline
                }
            }
        }

        Repeater {
            model: detail.current === "peers" ? detail.peers.slice(0, 40) : []

            Item {
                id: peerRow

                required property var modelData

                width: detail.width
                height: 37

                //: A hairline between rows, as a real table has.
                Rectangle {
                    width: parent.width
                    height: 1
                    color: Theme.outlineVariant
                }

                Row {
                    anchors.fill: parent
                    spacing: Theme.spacingS

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: peerHeader.width - peerHeader.clientWidth - peerHeader.speedWidth * 2 - peerHeader.hasWidth - Theme.spacingS * 4
                        text: peerRow.modelData.ip + (peerRow.modelData.port ? ":" + peerRow.modelData.port : "")
                        font.pixelSize: Theme.fontSizeSmall
                        font.family: "monospace"
                        color: Theme.surfaceText
                        wrapMode: Text.NoWrap
                        elide: Text.ElideMiddle
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: peerHeader.clientWidth
                        text: peerRow.modelData.client || "—"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: peerHeader.speedWidth
                        horizontalAlignment: Text.AlignRight
                        text: Fmt.speed(peerRow.modelData.downloadSpeed)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: peerHeader.speedWidth
                        horizontalAlignment: Text.AlignRight
                        text: Fmt.speed(peerRow.modelData.uploadSpeed)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: peerHeader.hasWidth
                        horizontalAlignment: Text.AlignRight
                        text: detail.peerHas(peerRow.modelData) + "%"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }
            }
        }

        //: qBittorrent's trackers, which aria2 does not report.
        SectionLabel {
            visible: detail.isQb && detail.uris.length > 0
            topPadding: Theme.spacingS
            text: "Trackers · " + detail.uris.length
        }

        Repeater {
            model: detail.isQb && detail.current === "peers" ? detail.uris.slice(0, 12) : []

            StyledText {
                required property var modelData

                width: detail.width
                text: modelData.uri + (modelData.status ? " · " + modelData.status : "")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.NoWrap
                elide: Text.ElideMiddle
            }
        }
    }

    // ======== connections (HTTP / FTP) ======================================
    //: Grouped by host, so it shows which mirror is pulling its weight.
    Column {
        width: parent.width
        visible: !detail.reviewing && detail.current === "connections"
        spacing: Theme.spacingXS

        SectionLabel {
            font.weight: Font.Normal
            text: detail.hostGroups.length + (detail.hostGroups.length === 1 ? " mirror · " : " mirrors · ")
                  + detail.servers.length + (detail.servers.length === 1 ? " connection" : " connections")
        }

        Repeater {
            model: detail.current === "connections" ? detail.hostGroups : []

            Rectangle {
                id: hostCard

                required property var modelData

                width: detail.width
                height: hostColumn.implicitHeight + 24
                radius: 12
                color: detail.tileColor

                Column {
                    id: hostColumn

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 8

                    Item {
                        width: parent.width
                        height: 20

                        Rectangle {
                            id: hostDot

                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: 8
                            height: 8
                            radius: 4
                            color: hostCard.modelData.slow || hostCard.modelData.speed === 0 ? Theme.warning : Theme.success
                        }

                        StyledText {
                            anchors.left: hostDot.right
                            anchors.leftMargin: Theme.spacingS
                            anchors.right: hostSpeed.left
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            text: hostCard.modelData.host
                            font.pixelSize: Theme.fontSizeSmall + 1
                            font.weight: Font.DemiBold
                            font.family: "monospace"
                            color: Theme.surfaceText
                            wrapMode: Text.NoWrap
                            elide: Text.ElideMiddle
                        }

                        StyledText {
                            id: hostSpeed

                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: Fmt.speed(hostCard.modelData.speed) + " · " + hostCard.modelData.count + " conn"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }

                    //: Its share of the speed, against the fastest server.
                    Rectangle {
                        width: parent.width
                        height: 6
                        radius: 3
                        visible: !hostCard.modelData.slow && detail.hostGroups.length > 0
                        color: Theme.surfaceContainerHighest

                        Rectangle {
                            width: parent.width * (detail.hostGroups[0].speed > 0 ? hostCard.modelData.speed / detail.hostGroups.reduce((a, g) => a + g.speed, 0) : 0)
                            height: parent.height
                            radius: 3
                            color: Theme.primary
                        }
                    }

                    StyledText {
                        visible: hostCard.modelData.slow
                        text: "Slow — " + Math.round(detail.hostGroups[0].speed / Math.max(1, hostCard.modelData.speed)) + "× slower than the fastest mirror"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.warning
                    }
                }
            }
        }

        SectionLabel {
            visible: detail.uris.length > 0
            topPadding: Theme.spacingXS
            text: (detail.uris.length === 1 ? "Link" : "Links · " + detail.uris.length)
        }

        Repeater {
            model: detail.current === "connections" ? detail.uris.slice(0, 12) : []

            StyledText {
                required property var modelData

                width: detail.width
                text: modelData.uri + (modelData.status ? " · " + modelData.status : "")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.NoWrap
                elide: Text.ElideMiddle
            }
        }
    }

    // ======== options, in plain words (board 6) =============================
    //: One labelled row each; changes save as they are made, and the line at
    //: the foot counts them with an Undo.
    component OptionRow: Item {
        id: optionRow

        property string label: ""
        property string hint: ""
        default property alias control: slot.data

        width: parent ? parent.width : 0
        height: Math.max(48, labels.implicitHeight + 12)

        Column {
            id: labels

            anchors.left: parent.left
            anchors.right: slot.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            StyledText {
                width: parent.width
                text: optionRow.label
                font.pixelSize: Theme.fontSizeSmall + 1
                color: Theme.surfaceText
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
            }

            StyledText {
                width: parent.width
                visible: optionRow.hint !== ""
                text: optionRow.hint
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
            }
        }

        Item {
            id: slot

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: childrenRect.width
            height: childrenRect.height
        }
    }

    Column {
        id: optionsBlock

        width: parent.width
        visible: detail.reviewing || (!detail.held && detail.current === "options")
        spacing: 0

        OptionRow {
            visible: !detail.reviewing
            label: "Download limit"

            UnitField {
                id: downField

                split: true
                fill: detail.tileColor
                kind: "speed"
                placeholderText: "none"
                onEdited: value => detail.queueOption("max-download-limit", value || "0")
            }
        }

        OptionRow {
            //: With sharing stopped, the upload limit is the manager's floor, not a choice.
            visible: !detail.reviewing && detail.isTorrent && !(detail.downloadOnly || detail.downloadOnlyEverywhere)
            label: "Upload limit"

            UnitField {
                id: upField

                split: true
                fill: detail.tileColor
                kind: "speed"
                placeholderText: "none"
                onEdited: value => detail.queueOption("max-upload-limit", value || "0")
            }
        }

        OptionRow {
            visible: !detail.reviewing && !detail.isQb
            label: "Connections per server"

            Stepper {
                id: connField

                fill: detail.tileColor
                minimum: 1
                maximum: 16
                onEdited: value => {
                    if (value)
                        detail.queueOption("max-connection-per-server", value)
                }
            }
        }

        OptionRow {
            visible: !detail.reviewing && !detail.isQb && !detail.isTorrent
            label: "Parts"

            Stepper {
                id: splitField

                fill: detail.tileColor
                minimum: 1
                onEdited: value => {
                    if (value)
                        detail.queueOption("split", value)
                }
            }
        }

        OptionRow {
            visible: detail.isTorrent && !detail.downloadOnlyEverywhere
            label: detail.reviewing ? "Download only, never seed" : "Stop sharing when done"

            BoolSwitch {
                checked: detail.downloadOnly
                onToggled: value => {
                    detail.downloadOnly = value
                    detail.queueOption("download-only", value ? "true" : "false")
                }
            }
        }

        StyledText {
            width: parent.width
            visible: !detail.reviewing && detail.isTorrent && detail.downloadOnlyEverywhere
            topPadding: 8
            bottomPadding: 8
            wrapMode: Text.WordWrap
            text: "Sharing stops when a download finishes, for every torrent (Settings)."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }

        //: qBittorrent's two playback helpers.
        OptionRow {
            visible: !detail.reviewing && detail.isQb
            label: "Download in order"
            hint: "Fetches each file from start to end, so its first parts can be used before it finishes. Usually slower."

            BoolSwitch {
                checked: detail.sequential
                onToggled: value => {
                    detail.sequential = value
                    detail.queueOption("sequential-download", value ? "true" : "false")
                }
            }
        }

        OptionRow {
            visible: !detail.reviewing && detail.isQb
            label: "First and last pieces first"
            hint: "Gets each file's start and end early, so it can be opened or previewed sooner."

            BoolSwitch {
                checked: detail.firstLast
                onToggled: value => {
                    detail.firstLast = value
                    detail.queueOption("first-last-piece-first", value ? "true" : "false")
                }
            }
        }

        //: Saved as they change; this says how many, and puts them all back.
        Item {
            width: parent.width
            height: 44
            visible: !detail.reviewing

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.topMargin: 4
                height: 1
                color: Theme.outlineVariant
            }

            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 2
                spacing: 8

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: detail.changeCount > 0
                    width: 6
                    height: 6
                    radius: 3
                    color: Theme.primary
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: {
                        if (detail.changeCount > 0)
                            return detail.changeCount + (detail.changeCount === 1 ? " change" : " changes") + " · applies live"
                                  + (detail.savedText === "Saving…" ? " · saving…" : "")
                        return detail.savedText === "Undone" ? "Undone" : "Changes apply live"
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }

            PillButton {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 2
                visible: detail.changeCount > 0
                size: 30
                kind: "text"
                text: "Undo"
                onClicked: detail.undoOptions()
            }
        }
    }

    // ---- what the automatic actions did to it (board 3) --------------------
    //: One line per action, how often and when last. The full record stays
    //: in Settings › Event log.
    Rectangle {
        id: actionsBlock

        readonly property var lines: Rules.actionLines(detail.detailData ? detail.detailData.triggers : [])
        readonly property int times: (detail.detailData && detail.detailData.triggers || []).length

        width: parent.width
        visible: !detail.reviewing && !detail.held && lines.length > 0
        height: visible ? actionsColumn.implicitHeight + 24 : 0
        radius: 14
        color: detail.tileColor

        Column {
            id: actionsColumn

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 12
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            spacing: 6

            Item {
                width: parent.width
                height: 20

                DankIcon {
                    id: actionsIcon

                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    name: "auto_fix_high"
                    size: 18
                    color: Theme.tertiary
                }

                StyledText {
                    anchors.left: actionsIcon.right
                    anchors.leftMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Actions on this download"
                    font.pixelSize: Theme.fontSizeSmall + 1
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                }

                StyledText {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: (actionsBlock.lines.length === 1 ? "1 action" : actionsBlock.lines.length + " actions")
                          + " · " + (actionsBlock.times === 1 ? "once" : actionsBlock.times + " times")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.outline
                }
            }

            Repeater {
                model: actionsBlock.lines

                Item {
                    id: actionLine

                    required property var modelData

                    width: actionsColumn.width
                    height: 18

                    StyledText {
                        id: actionRule

                        width: Math.min(implicitWidth, parent.width * 0.35)
                        anchors.verticalCenter: parent.verticalCenter
                        text: actionLine.modelData.rule
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                    }

                    StyledText {
                        anchors.left: actionRule.right
                        anchors.leftMargin: 14
                        anchors.right: actionWhen.left
                        anchors.rightMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        text: actionLine.modelData.what
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                    }

                    StyledText {
                        id: actionWhen

                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: actionLine.modelData.when
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.outline
                    }
                }
            }
        }
    }

    // ---- review: one button, everything at once ---------------------------
    Row {
        anchors.right: parent.right
        visible: detail.reviewing
        spacing: 8

        PillButton {
            size: 40
            kind: "text"
            text: "Cancel"
            onClicked: detail.cancelRequested()
        }

        PillButton {
            size: 40
            kind: "filled"
            text: detail.startLabel
            onClicked: detail.start()
        }
    }
}
