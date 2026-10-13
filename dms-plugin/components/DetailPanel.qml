import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt
import "../lib/FileTree.js" as FileTree

// A download's details, in the order people look for things: what is wrong
// (if anything), its files, its options, and only then the technical record.
// Every change saves as it is made; there is no Apply. While reviewing (the
// Add panel's held torrent) nothing is saved until Start.
Column {
    id: detail

    property var service: null
    property string gid: ""
    //: Shown by the Add panel for a torrent held for its file choice: its
    //: choices are kept here and sent together by the Start button.
    property bool reviewing: false
    //: Sent with the options on start while reviewing (the Add panel's folder).
    property var extraOptions: ({})

    signal started

    property var dl: ({})
    property var detailData: null
    property bool optionsInitialized: false

    // ---- files -----------------------------------------------------------
    //: file index -> 0 skip, 1 normal, 2 high, 3 maximum, as chosen here.
    property var levels: ({})
    property double editedAt: 0
    //: The file list's shape, replaced only when it changes, so the 2 s
    //: refresh does not rebuild the rows (and shut an open priority menu).
    property var structureFiles: []
    //: file index -> bytes done, refreshed every tick and read by the rows.
    property var progress: ({})
    property var collapsed: ({})
    property string filter: ""
    property string sortKey: "name"
    property bool sortDesc: false
    readonly property var levelLabels: ["Normal", "High", "Maximum"]

    readonly property var tree: FileTree.treeBuild(structureFiles, statusInfo.dir || "")
    readonly property var rows: structureFiles.length > 1 ? FileTree.treeRows(tree, levels, collapsed, filter, sortKey, sortDesc) : []
    readonly property var summary: FileTree.treeSummary(structureFiles, levels)

    // ---- options ---------------------------------------------------------
    property bool downloadOnly: false
    property bool sequential: false
    property bool firstLast: false
    property bool showAdvanced: false
    property bool showDetails: false
    property string savedText: ""
    property var pendingOptions: ({})

    readonly property bool isTorrent: !!statusInfo.bittorrent
    //: A torrent run by qBittorrent rather than aria2c.
    readonly property bool isQb: !!(detailData && detailData.engine === "qbittorrent")
    //: The global setting covers every torrent; the panel then just says so.
    readonly property bool downloadOnlyEverywhere: service ? service.downloadOnly : false

    readonly property var statusInfo: (detailData && detailData.status) || ({})
    readonly property var files: (detailData && detailData.files) || []
    readonly property var pieces: (detailData && detailData.pieceMap) || []
    readonly property var uris: (detailData && detailData.uris) || []
    readonly property var peers: (detailData && detailData.peers) || []
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

    //: Reused for another download (the Add panel's next torrent): start over.
    onGidChanged: {
        optionsInitialized = false
        detailData = null
        structureFiles = []
        levels = ({})
        editedAt = 0
        collapsed = ({})
        filter = ""
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
                        // here: a save in flight must not be undone by the refresh.
                        if (Date.now() - detail.editedAt > 4000) {
                            const server = ({})
                            for (const f of list)
                                server[f.index] = f.priority !== undefined ? f.priority : (f.selected === "true" ? 1 : 0)
                            if (JSON.stringify(server) !== JSON.stringify(detail.levels))
                                detail.levels = server
                        }
                        if (!detail.optionsInitialized) {
                            const opts = payload.options || ({})
                            splitField.text = opts["split"] || ""
                            connField.text = opts["max-connection-per-server"] || ""
                            downField.raw = opts["max-download-limit"] || ""
                            upField.raw = opts["max-upload-limit"] || ""
                            detail.downloadOnly = opts["download-only"] === "true"
                            detail.sequential = opts["sequential-download"] === "true"
                            detail.firstLast = opts["first-last-piece-first"] === "true"
                            detail.optionsInitialized = true
                        }
                    })
    }

    function doneOf(indices) {
        let total = 0
        for (const i of indices)
            total += progress[i] || 0
        return total
    }

    function toggleFold(key, open) {
        const next = Object.assign({}, collapsed)
        next[key] = open
        collapsed = next
    }

    function sortBy(key) {
        if (sortKey === key) {
            sortDesc = !sortDesc
        } else {
            sortKey = key
            sortDesc = key !== "name"   // biggest, most done, highest first
        }
    }

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
        savedText = "Saving…"
        optionTimer.restart()
    }

    function optionsToSend() {
        const options = ({})
        if (detail.isQb) {
            options["sequential-download"] = detail.sequential ? "true" : "false"
            options["first-last-piece-first"] = detail.firstLast ? "true" : "false"
        }
        if (splitField.text.trim() && !detail.isQb)
            options["split"] = splitField.text.trim()
        if (connField.text.trim() && !detail.isQb)
            options["max-connection-per-server"] = connField.text.trim()
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
            ToastService.showError("Aria", "Pick at least one file to download")
            return
        }
        const gid = detail.gid
        const resume = () => service.post("/api/download/" + gid + "/resume", null, "Started", () => detail.started())
        const sendOptions = () => {
            const options = detail.optionsToSend()
            if (Object.keys(options).length === 0)
                resume()
            else
                service.post("/api/download/" + gid + "/options", {
                                 "options": options
                             }, "", resume)
        }
        if (structureFiles.length > 1)
            service.post("/api/download/" + gid + "/files", {
                             "levels": levels
                         }, "", sendOptions)
        else
            sendOptions()
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
            if (detail.summary.chosen === 0) {
                detail.savedText = "Pick at least one file"
                return
            }
            detail.service.request("POST", "/api/download/" + detail.gid + "/files", {
                                       "levels": detail.levels
                                   }, (data, error) => {
                                       if (error) {
                                           detail.savedText = ""
                                           ToastService.showError("Aria", error)
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
                                           ToastService.showError("Aria", error)
                                       } else {
                                           detail.savedText = "Saved"
                                       }
                                   })
        }
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

            anchors.fill: parent
            anchors.margins: Theme.spacingS
            wrapMode: Text.WordWrap
            text: detail.statusInfo.errorMessage || ""
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.error
        }
    }

    // ---- files: a tree, like qBittorrent's --------------------------------
    Item {
        width: parent.width
        height: 32
        visible: detail.structureFiles.length > 1

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingS

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Files"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: detail.summary.chosen + " of " + detail.summary.count + " · " + Fmt.bytes(detail.summary.selected) + " of " + Fmt.bytes(detail.summary.total)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: !detail.reviewing && detail.savedText !== ""
                text: "· " + detail.savedText
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }

        DankButton {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            //: A torrent held for its file choice says how to go on.
            visible: !detail.reviewing && detail.isTorrent && detail.statusInfo.status === "paused"
            text: "Start download"
            iconName: "play_arrow"
            buttonHeight: 32
            backgroundColor: Theme.primary
            textColor: Theme.onPrimary
            onClicked: detail.service.post("/api/download/" + detail.gid + "/resume", null, "Started")
        }
    }

    Row {
        width: parent.width
        visible: detail.structureFiles.length > 1
        spacing: Theme.spacingS

        DankActionButton {
            anchors.verticalCenter: parent.verticalCenter
            iconName: detail.summary.chosen === detail.summary.count ? "check_box" : (detail.summary.chosen > 0 ? "indeterminate_check_box" : "check_box_outline_blank")
            iconColor: detail.summary.chosen > 0 ? Theme.primary : Theme.surfaceVariantText
            tooltipText: detail.summary.chosen === detail.summary.count ? "Download none" : "Download all"
            onClicked: detail.changeLevels(FileTree.treeSetChosen(detail.levels, detail.structureFiles.map(f => String(f.index)), detail.summary.chosen !== detail.summary.count))
        }

        DankTextField {
            anchors.verticalCenter: parent.verticalCenter
            visible: detail.structureFiles.length >= 12
            width: Math.min(220, parent.width * 0.4)
            height: 36
            leftIconName: "search"
            placeholderText: "Filter files"
            onTextChanged: detail.filter = text
        }

        Item {
            width: Math.max(0, parent.width - 40 - (detail.structureFiles.length >= 12 ? Math.min(220, parent.width * 0.4) + Theme.spacingS : 0) - 170 - Theme.spacingS * 2)
            height: 1
        }

        DankDropdown {
            anchors.verticalCenter: parent.verticalCenter
            width: 170
            height: 36
            compactMode: true
            currentValue: "Priority for all…"
            options: ["Priority for all…"].concat(detail.levelLabels)
            onValueChanged: label => {
                const level = detail.levelLabels.indexOf(label) + 1
                if (level > 0) {
                    const chosen = detail.structureFiles.map(f => String(f.index)).filter(i => FileTree.treeLevelOf(detail.levels, i) > 0)
                    detail.changeLevels(FileTree.treeSetLevel(detail.levels, chosen, level))
                }
                currentValue = "Priority for all…"
            }
        }
    }

    //: Column headers; a click sorts by that column, again reverses it.
    Row {
        id: header

        readonly property int sizeWidth: 64
        readonly property int doneWidth: 104
        readonly property int levelWidth: 124

        width: parent.width
        height: 22
        visible: detail.structureFiles.length > 1
        spacing: Theme.spacingS

        Repeater {
            model: [["name", "Name"], ["size", "Size"], ["progress", "Done"], ["priority", "Priority"]]

            StyledText {
                id: column

                required property var modelData
                required property int index

                width: index === 0 ? header.width - header.sizeWidth - header.doneWidth - header.levelWidth - Theme.spacingS * 3
                                   : [0, header.sizeWidth, header.doneWidth, header.levelWidth][index]
                horizontalAlignment: index === 1 ? Text.AlignRight : Text.AlignLeft
                text: column.modelData[1] + (detail.sortKey === column.modelData[0] ? (detail.sortDesc ? " ↓" : " ↑") : "")
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: detail.sortKey === column.modelData[0] ? Theme.primary : Theme.surfaceVariantText

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: detail.sortBy(column.modelData[0])
                }
            }
        }
    }

    Repeater {
        model: detail.rows

        Item {
            id: fileRow

            required property var modelData
            readonly property var r: modelData
            readonly property real done: detail.doneOf(r.indices)
            readonly property real pct: r.size ? Math.min(100, done / r.size * 100) : 0

            width: detail.width
            height: 34

            Rectangle {
                anchors.fill: parent
                radius: Theme.cornerRadius
                color: rowHover.hovered ? Theme.withAlpha(Theme.surfaceText, 0.05) : "transparent"
            }

            HoverHandler {
                id: rowHover
            }

            Row {
                anchors.fill: parent
                spacing: Theme.spacingS

                Row {
                    id: nameCell

                    width: header.width - header.sizeWidth - header.doneWidth - header.levelWidth - Theme.spacingS * 3
                    height: parent.height
                    spacing: 4

                    Item {
                        width: fileRow.r.depth * 16
                        height: 1
                    }

                    Item {
                        width: 20
                        height: parent.height

                        DankIcon {
                            anchors.centerIn: parent
                            visible: fileRow.r.isDir
                            name: fileRow.r.open ? "expand_more" : "chevron_right"
                            size: 18
                            color: Theme.surfaceVariantText
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: fileRow.r.isDir
                            cursorShape: Qt.PointingHandCursor
                            onClicked: detail.toggleFold(fileRow.r.key, fileRow.r.open)
                        }
                    }

                    Item {
                        width: 24
                        height: parent.height

                        DankIcon {
                            anchors.centerIn: parent
                            name: fileRow.r.state === 2 ? "check_box" : (fileRow.r.state === 1 ? "indeterminate_check_box" : "check_box_outline_blank")
                            size: 20
                            color: fileRow.r.state > 0 ? Theme.primary : Theme.surfaceVariantText
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: detail.changeLevels(FileTree.treeSetChosen(detail.levels, fileRow.r.indices, fileRow.r.state !== 2))
                        }
                    }

                    DankIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: fileRow.r.isDir
                        name: "folder"
                        size: 18
                        color: Theme.primary
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(0, nameCell.width - fileRow.r.depth * 16 - 20 - 24 - (fileRow.r.isDir ? 22 : 0) - 16)
                        text: fileRow.r.name
                        elide: Text.ElideMiddle
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: fileRow.r.isDir ? Font.Medium : Font.Normal
                        color: fileRow.r.state === 0 ? Theme.surfaceVariantText : Theme.surfaceText

                        MouseArea {
                            anchors.fill: parent
                            enabled: fileRow.r.isDir
                            cursorShape: fileRow.r.isDir ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: detail.toggleFold(fileRow.r.key, fileRow.r.open)
                        }
                    }
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    width: header.sizeWidth
                    horizontalAlignment: Text.AlignRight
                    text: Fmt.bytes(fileRow.r.size)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    width: header.doneWidth
                    spacing: 6

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: header.doneWidth - 46
                        height: 6
                        radius: 3
                        color: Theme.withAlpha(Theme.outline, 0.25)

                        Rectangle {
                            width: parent.width * fileRow.pct / 100
                            height: parent.height
                            radius: 3
                            color: fileRow.r.state === 0 ? Theme.outline : Theme.primary
                        }
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 40
                        horizontalAlignment: Text.AlignRight
                        text: (fileRow.pct >= 100 || fileRow.pct <= 0 ? Math.round(fileRow.pct) : fileRow.pct.toFixed(fileRow.pct < 10 ? 1 : 0)) + "%"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }

                Item {
                    width: header.levelWidth
                    height: parent.height

                    DankDropdown {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: fileRow.r.state > 0
                        width: parent.width
                        height: 30
                        compactMode: true
                        currentValue: fileRow.r.level === -1 ? "Mixed" : (detail.levelLabels[fileRow.r.level - 1] || "Normal")
                        options: detail.levelLabels
                        onValueChanged: label => {
                            const level = detail.levelLabels.indexOf(label) + 1
                            if (level > 0 && level !== fileRow.r.level) {
                                const chosen = fileRow.r.indices.filter(i => FileTree.treeLevelOf(detail.levels, i) > 0)
                                detail.changeLevels(FileTree.treeSetLevel(detail.levels, chosen, level))
                            }
                        }
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: fileRow.r.state === 0
                        text: "Not downloading"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }
            }
        }
    }

    // ---- options, in plain words ------------------------------------------
    Row {
        width: parent.width
        spacing: Theme.spacingS
        topPadding: Theme.spacingS

        StyledText {
            text: "Options"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            visible: !detail.reviewing && detail.savedText !== "" && detail.structureFiles.length <= 1
            text: "· " + detail.savedText
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }

    Item {
        width: parent.width
        height: 42

        StyledText {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Download speed limit"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceText
        }

        UnitField {
            id: downField

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 220
            kind: "speed"
            onEdited: value => detail.queueOption("max-download-limit", value || "0")
        }
    }

    Item {
        width: parent.width
        height: 42
        //: With sharing stopped, the upload limit is the manager's floor, not a choice.
        visible: detail.isTorrent && !(detail.downloadOnly || detail.downloadOnlyEverywhere)

        StyledText {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Upload speed limit"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceText
        }

        UnitField {
            id: upField

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 220
            kind: "speed"
            onEdited: value => detail.queueOption("max-upload-limit", value || "0")
        }
    }

    StyledText {
        width: parent.width
        visible: detail.isTorrent && detail.downloadOnlyEverywhere
        wrapMode: Text.WordWrap
        text: "Sharing stops when a download finishes, for every torrent (Settings)."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    Item {
        width: parent.width
        height: Math.max(40, shareText.implicitHeight + 8)
        visible: detail.isTorrent && !detail.downloadOnlyEverywhere

        Column {
            id: shareText

            anchors.left: parent.left
            anchors.right: shareSwitch.left
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            StyledText {
                text: "Stop sharing when done"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }

            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Uploads as little as possible and stops the moment the download finishes."
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
            }
        }

        BoolSwitch {
            id: shareSwitch

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: detail.downloadOnly
            onToggled: value => {
                detail.downloadOnly = value
                detail.queueOption("download-only", value ? "true" : "false")
            }
        }
    }

    // What only matters to someone tuning, folded away.
    Item {
        width: parent.width
        height: 32

        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: detail.showAdvanced ? "expand_more" : "chevron_right"
                size: 18
                color: Theme.surfaceVariantText
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Advanced"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: detail.showAdvanced = !detail.showAdvanced
        }
    }

    Repeater {
        model: detail.showAdvanced && detail.isQb ? [["sequential", "sequential-download", "Download in order", "Lets you start watching a video before it finishes. Can be slower."], ["firstLast", "first-last-piece-first", "First and last pieces first", "Helps media players open the file sooner."]] : []

        Item {
            id: advRow

            required property var modelData

            width: detail.width
            height: Math.max(40, advText.implicitHeight + 8)

            Column {
                id: advText

                anchors.left: parent.left
                anchors.leftMargin: 22
                anchors.right: advSwitch.left
                anchors.rightMargin: Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                StyledText {
                    text: advRow.modelData[2]
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                }

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: advRow.modelData[3]
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                }
            }

            BoolSwitch {
                id: advSwitch

                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: detail[advRow.modelData[0]]
                onToggled: value => {
                    detail[advRow.modelData[0]] = value
                    detail.queueOption(advRow.modelData[1], value ? "true" : "false")
                }
            }
        }
    }

    Grid {
        id: optionGrid

        width: parent.width
        visible: detail.showAdvanced && !detail.isQb
        columns: 2
        columnSpacing: Theme.spacingS
        rowSpacing: Theme.spacingXS

        Column {
            width: (optionGrid.width - Theme.spacingS) / 2
            spacing: 1

            StyledText {
                text: "Parts"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            DankTextField {
                id: splitField
                width: parent.width
                height: 40
                font.pixelSize: Theme.fontSizeSmall
                onTextChanged: if (activeFocus && text.trim()) detail.queueOption("split", text.trim())
            }
        }

        Column {
            width: (optionGrid.width - Theme.spacingS) / 2
            spacing: 1

            StyledText {
                text: "Connections per server"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            DankTextField {
                id: connField
                width: parent.width
                height: 40
                font.pixelSize: Theme.fontSizeSmall
                onTextChanged: if (activeFocus && text.trim()) detail.queueOption("max-connection-per-server", text.trim())
            }
        }
    }

    // ---- review: one button, everything at once ---------------------------
    DankButton {
        visible: detail.reviewing
        text: "Start download"
        iconName: "play_arrow"
        buttonHeight: 40
        backgroundColor: Theme.primary
        textColor: Theme.onPrimary
        onClicked: detail.start()
    }

    // ---- the technical record, folded away --------------------------------
    Item {
        width: parent.width
        height: 32
        visible: !detail.reviewing

        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: detail.showDetails ? "expand_more" : "chevron_right"
                size: 18
                color: Theme.surfaceVariantText
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Details"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: detail.showDetails = !detail.showDetails
        }
    }

    Column {
        width: parent.width
        visible: detail.showDetails && !detail.reviewing
        spacing: Theme.spacingS

        Repeater {
            model: [
                {
                    "label": "Folder",
                    "value": detail.statusInfo.dir || ""
                },
                {
                    "label": "File",
                    "value": detail.files.length === 1 ? detail.files[0].path : ""
                },
                {
                    "label": "Size",
                    "value": Fmt.bytes(detail.statusInfo.completedLength) + " of " + Fmt.bytes(detail.statusInfo.totalLength)
                },
                {
                    "label": "Connections",
                    "value": String(detail.statusInfo.connections || 0)
                },
                {
                    "label": "Added",
                    "value": Fmt.dateTime(detail.dl.addedAt)
                },
                {
                    "label": "Finished",
                    "value": Fmt.dateTime(detail.dl.finishedAt)
                },
                {
                    "label": "Info hash",
                    "value": detail.statusInfo.infoHash || ""
                },
                {
                    "label": "ID",
                    "value": detail.gid
                }
            ]

            Item {
                id: kv

                required property var modelData

                width: detail.width
                visible: String(kv.modelData.value).length > 0
                //: Tall enough for a long path to wrap instead of running into the next row.
                height: visible ? Math.max(18, kvValue.implicitHeight) : 0

                StyledText {
                    width: 92
                    text: kv.modelData.label
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    id: kvValue

                    x: 92 + Theme.spacingS
                    width: Math.max(0, parent.width - x)
                    text: kv.modelData.value
                    wrapMode: Text.WrapAnywhere
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            Quickshell.execDetached(["dms", "cl", "copy", String(kv.modelData.value)])
                            detail.service.notice("Copied " + kv.modelData.label.toLowerCase())
                        }
                    }
                }
            }
        }

        StyledText {
            width: parent.width
            visible: detail.pieces.length > 0
            text: "Pieces · " + (detail.statusInfo.numPieces || 0) + " × " + Fmt.bytes(detail.statusInfo.pieceLength || 0)
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: Theme.surfaceVariantText
            topPadding: Theme.spacingXS
        }

        Flow {
            width: parent.width
            visible: detail.pieces.length > 0
            spacing: 1

            Repeater {
                model: detail.showDetails ? detail.pieces : []

                Rectangle {
                    id: piece

                    required property var modelData

                    width: 4
                    height: 10
                    radius: 1
                    color: piece.modelData >= 100 ? Theme.primary : (piece.modelData > 0 ? Theme.withAlpha(Theme.primary, 0.45) : Theme.withAlpha(Theme.outline, 0.25))
                }
            }
        }

        Repeater {
            model: [
                {
                    "title": "Connections · " + detail.servers.length,
                    "items": detail.servers.map(s => [s.currentUri || s.uri || "", Fmt.speed(s.downloadSpeed)])
                },
                {
                    "title": (detail.isQb ? "Trackers · " : "Links · ") + detail.uris.length,
                    "items": detail.uris.slice(0, 12).map(u => [u.uri, u.status])
                },
                {
                    "title": "Peers · " + detail.peers.length,
                    "items": detail.peers.slice(0, 25).map(p => [p.ip + ":" + p.port + (p.client ? " · " + p.client : ""), "↓ " + Fmt.speed(p.downloadSpeed) + "  ↑ " + Fmt.speed(p.uploadSpeed)])
                }
            ]

            Column {
                id: listBlock

                required property var modelData

                width: detail.width
                visible: listBlock.modelData.items.length > 0
                spacing: 2

                StyledText {
                    text: listBlock.modelData.title
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: Theme.surfaceVariantText
                    topPadding: Theme.spacingXS
                }

                Repeater {
                    model: listBlock.modelData.items

                    Row {
                        id: line

                        required property var modelData

                        width: detail.width
                        height: 20
                        spacing: Theme.spacingXS

                        StyledText {
                            width: Math.max(0, parent.width - 150)
                            text: line.modelData[0]
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            elide: Text.ElideMiddle
                        }

                        StyledText {
                            width: 146
                            horizontalAlignment: Text.AlignRight
                            text: line.modelData[1]
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                        }
                    }
                }
            }
        }
    }
}
