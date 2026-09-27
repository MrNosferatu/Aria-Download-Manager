import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt

Column {
    id: panel

    property var service: null
    //: Simple: links, folder, start paused. Advanced: everything aria2 takes
    //: per download. The same split as the manager page's Add dialog.
    property bool advanced: false
    property bool paused: false
    property bool mirrors: false
    //: Starts at the global setting; sent only when it differs from it.
    property bool downloadOnly: service ? service.downloadOnly : false
    //: A .torrent is added paused; a magnet or .torrent link fetches its file
    //: list and its real download waits paused, so files can be chosen first.
    property bool pickFiles: false

    signal submitted

    function optionsPayload() {
        const options = ({})
        const put = (key, value) => {
            if (value && String(value).trim())
                options[key] = String(value).trim()
        }
        put("dir", dirField.text)
        put("out", outField.text)
        put("max-connection-per-server", connField.text)
        put("split", splitField.text)
        put("min-split-size", minSplitField.value)
        put("max-download-limit", limitField.value)
        if (pickFiles)
            options["pause-metadata"] = "true"
        if (service && downloadOnly !== service.downloadOnly)
            options["download-only"] = downloadOnly ? "true" : "false"
        put("referer", refererField.text)
        put("user-agent", uaField.text)
        put("all-proxy", proxyField.text)
        put("checksum", checksumField.text)

        const headers = headersField.text.split("\n").map(line => line.trim()).filter(line => line.length > 0)
        if (cookieField.text.trim())
            headers.push("Cookie: " + cookieField.text.trim())
        if (headers.length)
            options["header"] = headers
        return options
    }

    function submit() {
        const uris = urisField.text.split("\n").map(line => line.trim()).filter(line => line.length > 0)
        const torrent = torrentField.text.trim()
        if (!uris.length && !torrent) {
            ToastService.showError("Aria", "Paste a link or give a torrent path")
            return
        }

        const positionText = positionField.text.trim()
        const position = positionText === "" ? null : Number(positionText)

        if (torrent) {
            // aria2's file intake wants base64; base64(1) is the shortest path
            // from a local path to that payload.
            Proc.runCommand("ariaDownloadManager.torrent", ["base64", "-w0", torrent], (stdout, exitCode) => {
                                if (exitCode !== 0 || !stdout.trim()) {
                                    ToastService.showError("Aria", "Could not read " + torrent)
                                    return
                                }
                                const isMetalink = /\.meta(4|link)$/i.test(torrent)
                                panel.service.post("/api/downloads/file", {
                                                       "data": stdout.trim(),
                                                       "kind": isMetalink ? "metalink" : "torrent",
                                                       "filename": Fmt.basename(torrent),
                                                       "uris": uris,
                                                       "options": panel.optionsPayload(),
                                                       "position": position,
                                                       "paused": panel.paused || panel.pickFiles
                                                   }, panel.pickFiles ? "Added paused. Open it to choose files, then resume." : "Added",
                                                   () => panel.reset())
                            }, 0)
            return
        }

        service.post("/api/downloads", {
                         "uris": uris,
                         "options": optionsPayload(),
                         "position": position,
                         "paused": paused,
                         "mirrors": mirrors
                     }, pickFiles ? "Fetching the file list. Open the download to choose files, then resume." : "Added",
                     () => panel.reset())
    }

    function reset() {
        urisField.text = ""
        torrentField.text = ""
        panel.submitted()
    }

    spacing: Theme.spacingS

    Item {
        width: parent.width
        height: 32

        StyledText {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Add download"
            font.pixelSize: Theme.fontSizeLarge
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        DankButtonGroup {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            size: "small"
            model: ["Simple", "Advanced"]
            currentIndex: panel.advanced ? 1 : 0
            onSelectionChanged: (index, selected) => {
                if (selected)
                    panel.advanced = index === 1
            }
        }
    }

    MultiLineField {
        width: parent.width
        id: urisField
        minimumHeight: 62
        placeholderText: "Links, one per line: http, ftp, or magnet"
        onAccepted: panel.submit()
    }

    Row {
        width: parent.width
        spacing: Theme.spacingS

        DirectoryField {
            id: dirField
            objectName: "add"
            width: panel.advanced ? (parent.width - Theme.spacingS) / 2 : parent.width
            implicitHeight: 40
            placeholderText: "Save to: manager's download folder"
        }

        DankTextField {
            id: outField
            visible: panel.advanced
            width: (parent.width - Theme.spacingS) / 2
            height: 40
            leftIconName: "drive_file_rename_outline"
            placeholderText: "Save as (single file only)"
        }
    }

    Grid {
        width: parent.width
        visible: panel.advanced
        columns: 2
        columnSpacing: Theme.spacingS
        rowSpacing: Theme.spacingXS

        DankTextField {
            id: connField
            width: (parent.width - Theme.spacingS) / 2
            height: 40
            placeholderText: "Connections per server"
        }

        DankTextField {
            id: splitField
            width: (parent.width - Theme.spacingS) / 2
            height: 40
            placeholderText: "Parts per download"
        }

        UnitField {
            id: minSplitField
            width: (parent.width - Theme.spacingS) / 2
            kind: "size"
            placeholderText: "Smallest part"
        }

        UnitField {
            id: limitField
            width: (parent.width - Theme.spacingS) / 2
            kind: "speed"
            placeholderText: "Speed limit: none"
        }

        DankTextField {
            id: refererField
            width: (parent.width - Theme.spacingS) / 2
            height: 40
            placeholderText: "Referer"
        }

        DankTextField {
            id: uaField
            width: (parent.width - Theme.spacingS) / 2
            height: 40
            placeholderText: "User agent"
        }

        DankTextField {
            id: cookieField
            width: (parent.width - Theme.spacingS) / 2
            height: 40
            placeholderText: "Cookies (name=value; other=value)"
        }

        DankTextField {
            id: proxyField
            width: (parent.width - Theme.spacingS) / 2
            height: 40
            placeholderText: "Proxy"
        }

        DankTextField {
            id: checksumField
            width: (parent.width - Theme.spacingS) / 2
            height: 40
            placeholderText: "Checksum (sha-256=…)"
        }

        DankTextField {
            id: positionField
            width: (parent.width - Theme.spacingS) / 2
            height: 40
            placeholderText: "Queue position (blank adds at the end)"
        }

        DankTextField {
            id: torrentField
            width: (parent.width - Theme.spacingS) / 2
            height: 40
            leftIconName: "attach_file"
            placeholderText: "Torrent or metalink file path"
        }
    }

    MultiLineField {
        id: headersField
        width: parent.width
        visible: panel.advanced
        minimumHeight: 48
        placeholderText: "Extra headers, one per line: Name: value"
    }

    //: The torrent-specific choices, on their own line so the row below
    //: keeps room for the Add button at the panel's default width.
    Row {
        spacing: Theme.spacingL

        Row {
            spacing: Theme.spacingS

            BoolSwitch {
                anchors.verticalCenter: parent.verticalCenter
                checked: panel.pickFiles
                onToggled: value => panel.pickFiles = value
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Choose torrent files first"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }
        }

        Row {
            visible: panel.advanced
            spacing: Theme.spacingS

            BoolSwitch {
                anchors.verticalCenter: parent.verticalCenter
                checked: panel.downloadOnly
                onToggled: value => panel.downloadOnly = value
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Download only, never seed"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }
        }
    }

    Item {
        width: parent.width
        height: 40

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingL

            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingS

                BoolSwitch {
                    anchors.verticalCenter: parent.verticalCenter
                    checked: panel.paused
                    onToggled: value => panel.paused = value
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Start paused"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                }
            }

            Row {
                anchors.verticalCenter: parent.verticalCenter
                visible: panel.advanced
                spacing: Theme.spacingS

                BoolSwitch {
                    anchors.verticalCenter: parent.verticalCenter
                    checked: panel.mirrors
                    onToggled: value => panel.mirrors = value
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Links are mirrors of one file"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                }
            }
        }

        DankButton {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Add"
            iconName: "add"
            buttonHeight: 40
            backgroundColor: Theme.primary
            textColor: Theme.onPrimary
            onClicked: panel.submit()
        }
    }
}
