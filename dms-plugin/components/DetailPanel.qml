import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt

Column {
    id: detail

    property var service: null
    property string gid: ""
    //: Shown by the Add panel for a torrent held for its file choice: the one
    //: button applies options and files together and starts it.
    property bool reviewing: false
    //: Sent with the options on start while reviewing (the Add panel's folder).
    property var extraOptions: ({})

    signal started

    //: Reused for another download (the Add panel's next torrent): start over.
    onGidChanged: {
        optionsInitialized = false
        detailData = null
        refresh()
    }
    property var dl: ({})
    property var detailData: null
    property bool optionsInitialized: false
    //: file index -> priority level, as edited; applied with the button.
    property var filePriorities: ({})
    //: qBittorrent's four levels, in the order the manager uses (0..3).
    readonly property var priorityLabels: ["Do not download", "Normal", "High", "Maximum"]

    function setPriority(index, level) {
        const next = Object.assign({}, filePriorities)
        next[index] = level
        filePriorities = next
    }
    //: This torrent's own download-only state, as last loaded or toggled.
    property bool downloadOnly: false
    readonly property bool isTorrent: !!statusInfo.bittorrent
    //: A torrent run by qBittorrent rather than aria2c.
    readonly property bool isQb: !!(detailData && detailData.engine === "qbittorrent")
    property bool sequential: false
    property bool firstLast: false
    //: The global setting covers every torrent; the switch then just says so.
    readonly property bool downloadOnlyEverywhere: service ? service.downloadOnly : false

    readonly property var statusInfo: (detailData && detailData.status) || ({})
    readonly property var options: (detailData && detailData.options) || ({})
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

    function refresh() {
        if (!service || !gid)
            return
        service.get("/api/download/" + gid, (payload, error) => {
                        if (error) {
                            detail.detailData = null
                            return
                        }
                        detail.detailData = payload
                        if (!detail.optionsInitialized) {
                            const opts = payload.options || ({})
                            splitField.text = opts["split"] || ""
                            connField.text = opts["max-connection-per-server"] || ""
                            downField.raw = opts["max-download-limit"] || ""
                            upField.raw = opts["max-upload-limit"] || ""
                            detail.downloadOnly = opts["download-only"] === "true"
                            detail.sequential = opts["sequential-download"] === "true"
                            detail.firstLast = opts["first-last-piece-first"] === "true"
                            const levels = ({})
                            for (const f of (payload.files || []))
                                levels[f.index] = f.priority !== undefined ? f.priority : (f.selected === "true" ? 1 : 0)
                            detail.filePriorities = levels
                            detail.optionsInitialized = true
                        }
                    })
    }

    spacing: Theme.spacingS

    Component.onCompleted: refresh()

    Timer {
        interval: 2000
        running: true
        repeat: true
        onTriggered: detail.refresh()
    }

    // ---- piece map -------------------------------------------------------
    StyledText {
        width: parent.width
        visible: detail.pieces.length > 0
        text: "Pieces · " + (detail.statusInfo.numPieces || 0) + " × " + Fmt.bytes(detail.statusInfo.pieceLength || 0)
        font.pixelSize: Theme.fontSizeSmall
        font.weight: Font.Medium
        color: Theme.surfaceVariantText
    }

    Flow {
        width: parent.width
        visible: detail.pieces.length > 0
        spacing: 1

        Repeater {
            model: detail.pieces

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

    // ---- info ------------------------------------------------------------
    Repeater {
        model: [
            {
                "label": "ID",
                "value": detail.gid
            },
            {
                "label": "Folder",
                "value": detail.statusInfo.dir || ""
            },
            {
                "label": "Path",
                "value": detail.files.length ? detail.files[0].path : ""
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
                "label": "Error",
                "value": detail.statusInfo.errorMessage ? detail.statusInfo.errorMessage + " (" + detail.statusInfo.errorCode + ")" : ""
            }
        ]

        Row {
            id: kv

            required property var modelData

            width: detail.width
            visible: String(kv.modelData.value).length > 0
            height: visible ? 18 : 0
            spacing: Theme.spacingS

            StyledText {
                width: 92
                text: kv.modelData.label
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            StyledText {
                width: Math.max(0, parent.width - 92 - Theme.spacingS)
                text: kv.modelData.value
                font.pixelSize: Theme.fontSizeSmall
                color: kv.modelData.label === "Error" ? Theme.error : Theme.surfaceText
                elide: Text.ElideMiddle

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

    // ---- per-download options -------------------------------------------
    StyledText {
        width: parent.width
        text: "Options for this download"
        font.pixelSize: Theme.fontSizeSmall
        font.weight: Font.Medium
        color: Theme.surfaceVariantText
        topPadding: Theme.spacingXS
    }

    Grid {
        id: optionGrid

        width: parent.width
        columns: 2
        columnSpacing: Theme.spacingS
        rowSpacing: Theme.spacingXS

        Column {
            width: (optionGrid.width - Theme.spacingS) / 2
            spacing: 1
            //: Parts and connections are aria2's; qBittorrent manages its own peers.
            visible: !detail.isQb

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
            }
        }

        Column {
            width: (optionGrid.width - Theme.spacingS) / 2
            spacing: 1
            visible: !detail.isQb

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
            }
        }

        Column {
            width: (optionGrid.width - Theme.spacingS) / 2
            spacing: 1

            StyledText {
                text: "Download limit"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            UnitField {
                id: downField
                width: parent.width
                kind: "speed"
            }
        }

        Column {
            width: (optionGrid.width - Theme.spacingS) / 2
            spacing: 1
            //: With download-only on the upload limit is the floor, not a choice.
            visible: !(detail.isTorrent && (detail.downloadOnly || detail.downloadOnlyEverywhere))

            StyledText {
                text: "Upload limit"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            UnitField {
                id: upField
                width: parent.width
                kind: "speed"
            }
        }
    }

    Row {
        visible: detail.isTorrent
        spacing: Theme.spacingS

        BoolSwitch {
            anchors.verticalCenter: parent.verticalCenter
            checked: detail.downloadOnly || detail.downloadOnlyEverywhere
            enabled: !detail.downloadOnlyEverywhere
            onToggled: value => detail.downloadOnly = value
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: detail.downloadOnlyEverywhere ? "Download only, never seed · on for every torrent in Settings"
                                                : "Download only, never seed"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceText
        }
    }

    Repeater {
        model: detail.isQb ? [["sequential", "Download in order"], ["firstLast", "First and last pieces first"]] : []

        Row {
            id: qbSwitch

            required property var modelData

            spacing: Theme.spacingS

            BoolSwitch {
                anchors.verticalCenter: parent.verticalCenter
                checked: detail[qbSwitch.modelData[0]]
                onToggled: value => detail[qbSwitch.modelData[0]] = value
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: qbSwitch.modelData[1]
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }
        }
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
        if (detail.reviewing)
            Object.assign(options, detail.extraOptions)
        return options
    }

    DankButton {
        visible: !detail.reviewing
        text: "Apply"
        buttonHeight: 40
        iconName: "check"
        onClicked: detail.service.post("/api/download/" + detail.gid + "/options", {
                                           "options": detail.optionsToSend()
                                       }, "Applied")
    }

    // ---- files -----------------------------------------------------------
    StyledText {
        width: parent.width
        visible: detail.files.length > 0
        text: "Files" + (detail.files.length > 1 ? " · " + detail.files.length : "")
        font.pixelSize: Theme.fontSizeSmall
        font.weight: Font.Medium
        color: Theme.surfaceVariantText
        topPadding: Theme.spacingXS
    }

    Row {
        visible: detail.files.length > 1
        width: detail.width
        spacing: Theme.spacingS

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, parent.width - setAll.width - Theme.spacingS)
            text: detail.isQb ? "Higher priorities get their pieces first."
                              : "Higher priorities finish before lower ones start."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            elide: Text.ElideRight
        }

        DankDropdown {
            id: setAll

            width: 170
            height: 36
            compactMode: true
            currentValue: "Set all…"
            options: ["Set all…"].concat(detail.priorityLabels)
            onValueChanged: label => {
                const level = detail.priorityLabels.indexOf(label)
                if (level < 0)
                    return
                const next = ({})
                for (const f of detail.files)
                    next[f.index] = level
                detail.filePriorities = next
                currentValue = "Set all…"
            }
        }
    }

    Repeater {
        model: detail.files

        Row {
            id: fileRow

            required property var modelData
            readonly property int level: {
                const v = detail.filePriorities[fileRow.modelData.index]
                return v === undefined ? 1 : v
            }

            width: detail.width
            height: detail.files.length > 1 ? 36 : 22
            spacing: Theme.spacingXS

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, parent.width - sizeText.width - (prio.visible ? prio.width : 0) - Theme.spacingXS * 2)
                text: Fmt.basename(fileRow.modelData.path)
                font.pixelSize: Theme.fontSizeSmall
                font.strikeout: fileRow.level === 0 && detail.files.length > 1
                color: fileRow.level === 0 ? Theme.surfaceVariantText : Theme.surfaceText
                elide: Text.ElideMiddle
            }

            StyledText {
                id: sizeText

                anchors.verticalCenter: parent.verticalCenter
                text: Fmt.bytes(fileRow.modelData.completedLength) + " / " + Fmt.bytes(fileRow.modelData.length)
                      + (fileRow.modelData.waitingForTier ? " · after higher priority" : "")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            DankDropdown {
                id: prio

                anchors.verticalCenter: parent.verticalCenter
                visible: detail.files.length > 1
                width: 170
                height: 32
                compactMode: true
                currentValue: detail.priorityLabels[fileRow.level]
                options: detail.priorityLabels
                onValueChanged: label => {
                    const level = detail.priorityLabels.indexOf(label)
                    if (level >= 0 && level !== fileRow.level)
                        detail.setPriority(fileRow.modelData.index, level)
                }
            }
        }
    }

    DankButton {
        visible: detail.files.length > 1 || detail.reviewing
        //: A torrent waiting on this choice starts with it; a running one just
        //: takes the new priorities.
        readonly property bool startsIt: detail.reviewing || detail.statusInfo.status === "paused"
        text: startsIt ? "Apply and start" : "Apply file choices"
        buttonHeight: 40
        iconName: startsIt ? "play_arrow" : "checklist"
        onClicked: {
            const start = startsIt
            const levels = ({})
            let any = false
            for (const f of detail.files) {
                const v = detail.filePriorities[f.index]
                levels[f.index] = v === undefined ? 1 : v
                if (levels[f.index] > 0)
                    any = true
            }
            if (!any) {
                ToastService.showError("Aria", "Pick at least one file to download")
                return
            }
            const gid = detail.gid
            const resume = () => detail.service.post("/api/download/" + gid + "/resume", null, "Started",
                                                    () => detail.started())
            detail.service.post("/api/download/" + gid + "/files", {
                                    "levels": levels
                                }, start ? "" : "File choices applied", () => {
                                    if (!start)
                                        return
                                    if (!detail.reviewing) {
                                        resume()
                                        return
                                    }
                                    // Held for review: its options go with the start.
                                    const options = detail.optionsToSend()
                                    if (Object.keys(options).length === 0) {
                                        resume()
                                        return
                                    }
                                    detail.service.post("/api/download/" + gid + "/options", {
                                                            "options": options
                                                        }, "", resume)
                                })
        }
    }

    // ---- live connections ------------------------------------------------
    StyledText {
        width: parent.width
        visible: detail.servers.length > 0
        text: "Connections · " + detail.servers.length
        font.pixelSize: Theme.fontSizeSmall
        font.weight: Font.Medium
        color: Theme.surfaceVariantText
        topPadding: Theme.spacingXS
    }

    Repeater {
        model: detail.servers

        Row {
            id: serverRow

            required property var modelData

            width: detail.width
            height: 22
            spacing: Theme.spacingXS

            StyledText {
                width: Math.max(0, parent.width - 90)
                text: serverRow.modelData.currentUri || serverRow.modelData.uri || ""
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                elide: Text.ElideMiddle
            }

            StyledText {
                text: Fmt.speed(serverRow.modelData.downloadSpeed)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }
        }
    }

    // ---- urls ------------------------------------------------------------
    StyledText {
        width: parent.width
        visible: detail.uris.length > 0
        text: (detail.isQb ? "Trackers · " : "Links · ") + detail.uris.length
        font.pixelSize: Theme.fontSizeSmall
        font.weight: Font.Medium
        color: Theme.surfaceVariantText
        topPadding: Theme.spacingXS
    }

    Repeater {
        model: detail.uris.slice(0, 12)

        Row {
            id: uriRow

            required property var modelData

            width: detail.width
            height: 22
            spacing: Theme.spacingXS

            StyledText {
                width: Math.max(0, parent.width - 70)
                text: uriRow.modelData.uri
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                elide: Text.ElideMiddle
            }

            StyledText {
                text: uriRow.modelData.status
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }
        }
    }

    // ---- peers -----------------------------------------------------------
    StyledText {
        width: parent.width
        visible: detail.peers.length > 0
        text: "Peers · " + detail.peers.length
        font.pixelSize: Theme.fontSizeSmall
        font.weight: Font.Medium
        color: Theme.surfaceVariantText
        topPadding: Theme.spacingXS
    }

    Repeater {
        model: detail.peers.slice(0, 25)

        Row {
            id: peerRow

            required property var modelData

            width: detail.width
            height: 22
            spacing: Theme.spacingXS

            StyledText {
                width: Math.max(0, parent.width - 150)
                text: peerRow.modelData.ip + ":" + peerRow.modelData.port
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                elide: Text.ElideRight
            }

            StyledText {
                text: "↓ " + Fmt.speed(peerRow.modelData.downloadSpeed) + "  ↑ " + Fmt.speed(peerRow.modelData.uploadSpeed)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }
        }
    }
}
