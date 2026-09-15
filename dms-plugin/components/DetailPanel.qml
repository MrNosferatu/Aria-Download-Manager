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
    property var dl: ({})
    property var detailData: null
    property bool optionsInitialized: false
    property var selectedFiles: []

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
                            detail.selectedFiles = (payload.files || []).filter(f => f.selected === "true").map(f => Number(f.index))
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

    DankButton {
        text: "Apply"
        buttonHeight: 40
        iconName: "check"
        onClicked: {
            const options = ({})
            if (splitField.text.trim())
                options["split"] = splitField.text.trim()
            if (connField.text.trim())
                options["max-connection-per-server"] = connField.text.trim()
            if (downField.value)
                options["max-download-limit"] = downField.value
            if (upField.value)
                options["max-upload-limit"] = upField.value
            detail.service.post("/api/download/" + detail.gid + "/options", {
                                    "options": options
                                }, "Applied")
        }
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

    Repeater {
        model: detail.files

        Row {
            id: fileRow

            required property var modelData

            width: detail.width
            height: 22
            spacing: Theme.spacingXS

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                visible: detail.files.length > 1
                name: detail.selectedFiles.indexOf(Number(fileRow.modelData.index)) >= 0 ? "check_box" : "check_box_outline_blank"
                size: Theme.iconSizeSmall - 2
                color: Theme.primary

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        const index = Number(fileRow.modelData.index)
                        const next = detail.selectedFiles.slice()
                        const at = next.indexOf(index)
                        if (at >= 0)
                            next.splice(at, 1)
                        else
                            next.push(index)
                        detail.selectedFiles = next
                    }
                }
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, parent.width - 130)
                text: Fmt.basename(fileRow.modelData.path)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                elide: Text.ElideMiddle
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: Fmt.bytes(fileRow.modelData.completedLength) + " / " + Fmt.bytes(fileRow.modelData.length)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }
    }

    DankButton {
        visible: detail.files.length > 1
        text: "Apply file selection"
        buttonHeight: 40
        iconName: "checklist"
        onClicked: {
            if (!detail.selectedFiles.length) {
                ToastService.showError("Aria", "Pick at least one file")
                return
            }
            detail.service.post("/api/download/" + detail.gid + "/select", {
                                    "indices": detail.selectedFiles
                                }, "File selection applied")
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
        text: "Links · " + detail.uris.length
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
