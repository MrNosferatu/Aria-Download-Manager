import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt

Column {
    id: panel

    property var service: null
    property bool showAdvanced: false
    property bool paused: false
    property bool mirrors: false

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
        put("Referer", refererField.text)
        put("User-Agent", uaField.text)
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
            ToastService.showError("aria2c", "Give a URL or a .torrent path")
            return
        }

        const positionText = positionField.text.trim()
        const position = positionText === "" ? null : Number(positionText)

        if (torrent) {
            // aria2's file intake wants base64; base64(1) is the shortest path
            // from a local path to that payload.
            Proc.runCommand("aria2cManager.torrent", ["base64", "-w0", torrent], (stdout, exitCode) => {
                                if (exitCode !== 0 || !stdout.trim()) {
                                    ToastService.showError("aria2c", "Could not read " + torrent)
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
                                                       "paused": panel.paused
                                                   }, "Queued", () => panel.reset())
                            }, 0)
            return
        }

        service.post("/api/downloads", {
                         "uris": uris,
                         "options": optionsPayload(),
                         "position": position,
                         "paused": paused,
                         "mirrors": mirrors
                     }, "Queued", () => panel.reset())
    }

    function reset() {
        urisField.text = ""
        torrentField.text = ""
        panel.submitted()
    }

    spacing: Theme.spacingS

    MultiLineField {
        width: parent.width
        id: urisField
        minimumHeight: 62
        placeholderText: "URLs — one per line (http, ftp, magnet:)"
        onAccepted: panel.submit()
    }

    Row {
        width: parent.width
        spacing: Theme.spacingS

        DirectoryField {
            id: dirField
            objectName: "add"
            width: (parent.width - Theme.spacingS) / 2
            implicitHeight: 40
            placeholderText: "Save to directory (default)"
        }

        DankTextField {
            id: outField
            width: (parent.width - Theme.spacingS) / 2
            height: 40
            leftIconName: "drive_file_rename_outline"
            placeholderText: "Rename to (single file only)"
        }
    }

    Row {
        width: parent.width
        spacing: Theme.spacingS

        DankButton {
            text: panel.showAdvanced ? "Fewer options" : "More options"
            iconName: panel.showAdvanced ? "expand_less" : "expand_more"
            buttonHeight: 40
            backgroundColor: Theme.surfaceContainerHigh
            textColor: Theme.surfaceText
            onClicked: panel.showAdvanced = !panel.showAdvanced
        }

        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: panel.paused ? "check_box" : "check_box_outline_blank"
                size: Theme.iconSizeSmall
                color: panel.paused ? Theme.primary : Theme.surfaceVariantText

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: panel.paused = !panel.paused
                }
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Add paused"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }
        }

        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: panel.mirrors ? "check_box" : "check_box_outline_blank"
                size: Theme.iconSizeSmall
                color: panel.mirrors ? Theme.primary : Theme.surfaceVariantText

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: panel.mirrors = !panel.mirrors
                }
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "URLs are mirrors of one file"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }
        }
    }

    Grid {
        width: parent.width
        visible: panel.showAdvanced
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
            placeholderText: "Split (parts)"
        }

        UnitField {
            id: minSplitField
            width: (parent.width - Theme.spacingS) / 2
            kind: "size"
            placeholderText: "Min part size"
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
            placeholderText: "User-Agent"
        }

        DankTextField {
            id: cookieField
            width: (parent.width - Theme.spacingS) / 2
            height: 40
            placeholderText: "Cookie header (k=v; k2=v2)"
        }

        DankTextField {
            id: proxyField
            width: (parent.width - Theme.spacingS) / 2
            height: 40
            placeholderText: "Proxy (all-proxy)"
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
            placeholderText: "Queue position (end)"
        }

        DankTextField {
            id: torrentField
            width: (parent.width - Theme.spacingS) / 2
            height: 40
            leftIconName: "attach_file"
            placeholderText: "/path/to/file.torrent"
        }
    }

    MultiLineField {
        id: headersField
        width: parent.width
        visible: panel.showAdvanced
        minimumHeight: 48
        placeholderText: "Extra headers — one per line, Name: value"
    }

    DankButton {
        text: "Add download"
        iconName: "add"
        buttonHeight: 40
        backgroundColor: Theme.primary
        textColor: Theme.onPrimary
        onClicked: panel.submit()
    }
}
