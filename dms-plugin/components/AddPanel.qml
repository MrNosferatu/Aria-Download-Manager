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
    //: Every add is reviewed before it starts: "form" (links and options),
    //: "busy" (checking them), "file" (name, size, folder of plain links) and
    //: "torrent" (a held torrent's files and priorities, one at a time).
    property string stage: "form"
    property var formOptions: ({})
    property var formPosition: null
    //: Plain links as checked: {url, name, size, contentType, resumable}.
    property var entries: []
    //: Torrents added held, waiting for their file choice.
    property var held: []
    property var folderInfo: ({})

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

    // ---- step 1: check what was given ----------------------------------
    function isTorrentLink(uri) {
        return /^magnet:/i.test(uri) || /\.torrent([?#]|$)/i.test(uri)
    }

    function submit() {
        const uris = urisField.text.split("\n").map(line => line.trim()).filter(line => line.length > 0)
        const torrent = torrentField.text.trim()
        if (!uris.length && !torrent) {
            ToastService.showError("Aria", "Paste a link or give a torrent path")
            return
        }
        const positionText = positionField.text.trim()
        formPosition = positionText === "" ? null : Number(positionText)
        formOptions = optionsPayload()
        stage = "busy"

        const found = []
        const heldNow = []
        let waiting = 1
        const finish = () => {
            if (--waiting > 0)
                return
            panel.entries = found
            panel.held = heldNow
            panel.next()
        }
        const hold = (list, add) => {
            waiting++
            add((data, error) => {
                    if (error)
                        ToastService.showError("Aria", error)
                    else
                        for (const gid of (data && data.gids) || [])
                            heldNow.push(gid)
                    finish()
                })
        }
        const addHeldLinks = list => hold(list, done => service.request("POST", "/api/downloads", {
                                                                          "uris": list,
                                                                          "options": Object.assign({}, formOptions, {
                                                                                                       "pause-metadata": "true"
                                                                                                   }),
                                                                          "position": formPosition
                                                                      }, done))

        if (torrent) {
            // aria2's file intake wants base64; base64(1) is the shortest path
            // from a local path to that payload.
            hold([], done => Proc.runCommand("ariaDownloadManager.torrent", ["base64", "-w0", torrent], (stdout, exitCode) => {
                                                 if (exitCode !== 0 || !stdout.trim()) {
                                                     done(null, "Could not read " + torrent)
                                                     return
                                                 }
                                                 const isMetalink = /\.meta(4|link)$/i.test(torrent)
                                                 service.request("POST", "/api/downloads/file", {
                                                                     "data": stdout.trim(),
                                                                     "kind": isMetalink ? "metalink" : "torrent",
                                                                     "filename": Fmt.basename(torrent),
                                                                     "options": Object.assign({}, formOptions, {
                                                                                                  "pause-metadata": "true"
                                                                                              }),
                                                                     "position": formPosition,
                                                                     "paused": true
                                                                 }, done)
                                             }, 0))
        }

        const torrents = uris.filter(u => isTorrentLink(u))
        if (torrents.length)
            addHeldLinks(torrents)

        if (mirrors) {
            // One file from several places: nothing to check per link.
            const plain = uris.filter(u => !isTorrentLink(u))
            if (plain.length)
                found.push({
                               "url": plain[0],
                               "mirrors": plain,
                               "name": Fmt.basename(plain[0].split("?")[0]),
                               "size": null,
                               "contentType": "",
                               "resumable": null
                           })
        } else {
            for (const url of uris.filter(u => !isTorrentLink(u))) {
                waiting++
                service.request("POST", "/api/intake/probe", {
                                    "url": url
                                }, (data, error) => {
                                    const probe = data || ({})
                                    if (probe.kind === "torrent") {
                                        addHeldLinks([url])
                                    } else {
                                        found.push({
                                                       "url": url,
                                                       "name": probe.name || Fmt.basename(url.split("?")[0]),
                                                       "size": probe.size,
                                                       "contentType": probe.contentType || "",
                                                       "resumable": probe.resumable
                                                   })
                                    }
                                    finish()
                                })
            }
        }
        service.get("/api/folders?name=" + encodeURIComponent(uris.length ? Fmt.basename(uris[0]) : ""), (data, error) => {
                        panel.folderInfo = data || ({})
                    })
        finish()
    }

    //: Plain links first, then each held torrent; then back to the form.
    function next() {
        if (entries.length) {
            singleName.text = entries.length === 1 ? (formOptions["out"] || entries[0].name) : ""
            reviewDir.text = formOptions["dir"] || ""
            stage = "file"
        } else if (held.length) {
            stage = "torrent"
        } else {
            urisField.text = ""
            torrentField.text = ""
            stage = "form"
            panel.submitted()
        }
    }

    // ---- step 2: plain links ------------------------------------------
    function looksLikePage(entry) {
        return /text\/html/i.test(entry.contentType || "") && /\.[a-z0-9]+$/i.test(entry.name || "")
            && !/\.(html?|xhtml|php|aspx?|jsp|txt|xml|json)$/i.test(entry.name || "")
    }

    function startFiles(later) {
        const options = Object.assign({}, formOptions)
        delete options["out"]  // a name only ever belongs to a single file
        if (reviewDir.text.trim())
            options["dir"] = reviewDir.text.trim()
        else
            delete options["dir"]
        const list = entries
        let index = 0
        for (const entry of list) {
            const own = Object.assign({}, options)
            if (list.length === 1 && singleName.text.trim())
                own["out"] = singleName.text.trim()
            service.request("POST", "/api/downloads", {
                                "uris": entry.mirrors || [entry.url],
                                "options": own,
                                "position": formPosition === null ? null : formPosition + index,
                                "paused": later || panel.paused,
                                "mirrors": !!entry.mirrors
                            }, (data, error) => {
                                if (error)
                                    ToastService.showError("Aria", error)
                            })
            index++
        }
        service.notice(later ? "Added paused" : "Added")
        entries = []
        next()
    }

    // ---- step 2: held torrents ----------------------------------------
    //: The download the held one became, for aria2's magnet → torrent step.
    readonly property string reviewGid: {
        if (!held.length || !service)
            return ""
        const origin = held[0]
        for (const dl of service.downloads)
            if (dl.following === origin)
                return dl.gid
        return origin
    }
    readonly property var reviewRow: {
        if (!service)
            return null
        for (const dl of service.downloads)
            if (dl.gid === reviewGid)
                return dl
        return null
    }
    readonly property bool reviewReady: !!reviewRow && !reviewRow.isMetadata && reviewRow.numFiles > 0

    function torrentDone() {
        held = held.slice(1)
        next()
    }

    function cancelTorrent() {
        const gids = [held[0]]
        if (reviewGid && reviewGid !== held[0])
            gids.push(reviewGid)
        for (const gid of gids)
            service.request("DELETE", "/api/download/" + gid + "?force=true&purge=true&delete_files=true", null, () => {})
        torrentDone()
    }

    function back() {
        // Torrents held for review that never got a choice go again.
        for (const gid of held)
            service.request("DELETE", "/api/download/" + gid + "?force=true&purge=true&delete_files=true", null, () => {})
        if (reviewGid && held.length && reviewGid !== held[0])
            service.request("DELETE", "/api/download/" + reviewGid + "?force=true&purge=true&delete_files=true", null, () => {})
        entries = []
        held = []
        stage = "form"
    }

    spacing: Theme.spacingS

    Column {
        width: parent.width
        visible: panel.stage === "form"
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

        //: The torrent-specific choice, on its own line so the row below keeps
        //: room for the Add button at the panel's default width.
        Row {
            visible: panel.advanced
            spacing: Theme.spacingL

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
                text: "Next"
                iconName: "arrow_forward"
                buttonHeight: 40
                backgroundColor: Theme.primary
                textColor: Theme.onPrimary
                onClicked: panel.submit()
            }
        }
    }

    // ---- the review step ----------------------------------------------
    Row {
        visible: panel.stage === "busy"
        spacing: Theme.spacingS

        DankIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: "hourglass_top"
            size: Theme.iconSizeSmall
            color: Theme.surfaceVariantText
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: "Checking the links…"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }

    Column {
        width: parent.width
        visible: panel.stage === "file"
        spacing: Theme.spacingS

        StyledText {
            text: panel.entries.length === 1 ? "New download" : panel.entries.length + " downloads"
            font.pixelSize: Theme.fontSizeLarge
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            visible: panel.entries.some(e => panel.looksLikePage(e))
            wrapMode: Text.WordWrap
            text: "The site answered with a web page, not the file (usually a captcha, a login or a link good for one download). Download it in a browser instead."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.error
        }

        DankTextField {
            id: singleName
            width: parent.width
            height: 40
            visible: panel.entries.length === 1
            leftIconName: "drive_file_rename_outline"
            placeholderText: "File name"
        }

        Repeater {
            model: panel.entries

            Row {
                id: entryRow

                required property var modelData

                width: parent.width
                spacing: Theme.spacingS

                StyledText {
                    width: parent.width - facts.width - Theme.spacingS
                    visible: panel.entries.length > 1
                    text: entryRow.modelData.name
                    elide: Text.ElideMiddle
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                }

                StyledText {
                    id: facts

                    text: (entryRow.modelData.size ? Fmt.bytes(entryRow.modelData.size) : "Size unknown")
                          + (entryRow.modelData.contentType ? " · " + entryRow.modelData.contentType.split(";")[0] : "")
                          + (entryRow.modelData.resumable === true ? " · resumable" : entryRow.modelData.resumable === false ? " · cannot resume" : "")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }
        }

        StyledText {
            text: "Save to"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }

        DankDropdown {
            width: parent.width
            height: 40
            compactMode: true
            //: The folders that already mean something; the field below takes
            //: anything else, typed or chosen.
            readonly property var presets: (panel.folderInfo.presets || [])
            currentValue: "Folders…"
            options: ["Folders…"].concat(presets.map(p => p.label + " · " + p.path))
            onValueChanged: label => {
                for (const p of presets)
                    if (label === p.label + " · " + p.path)
                        reviewDir.text = p.path
            }
        }

        DirectoryField {
            id: reviewDir
            objectName: "review"
            width: parent.width
            placeholderText: panel.folderInfo.sorting && panel.folderInfo.suggested
                             ? "Automatic: " + panel.folderInfo.suggested
                             : "Download folder: " + (panel.folderInfo.base || "")
        }

        Row {
            anchors.right: parent.right
            spacing: Theme.spacingS

            DankButton {
                text: "Back"
                buttonHeight: 40
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                onClicked: panel.back()
            }

            DankButton {
                text: "Download later"
                buttonHeight: 40
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                onClicked: panel.startFiles(true)
            }

            DankButton {
                text: "Download"
                iconName: "download"
                buttonHeight: 40
                backgroundColor: Theme.primary
                textColor: Theme.onPrimary
                onClicked: panel.startFiles(false)
            }
        }
    }

    Column {
        width: parent.width
        visible: panel.stage === "torrent"
        spacing: Theme.spacingS

        Item {
            width: parent.width
            height: 40

            StyledText {
                anchors.left: parent.left
                anchors.right: cancelTorrentButton.left
                anchors.verticalCenter: parent.verticalCenter
                text: panel.reviewRow ? panel.reviewRow.name : "Torrent"
                elide: Text.ElideRight
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            DankButton {
                id: cancelTorrentButton

                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Cancel"
                buttonHeight: 36
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                onClicked: panel.cancelTorrent()
            }
        }

        StyledText {
            visible: !panel.reviewReady
            text: "Getting the file list from peers…" + (panel.reviewRow && panel.reviewRow.connections ? " · " + panel.reviewRow.connections + " connected" : "")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }

        Loader {
            width: parent.width
            active: panel.stage === "torrent" && panel.reviewReady

            sourceComponent: DetailPanel {
                width: parent ? parent.width : 0
                service: panel.service
                gid: panel.reviewGid
                dl: panel.reviewRow || ({})
                reviewing: true
                onStarted: panel.torrentDone()
            }
        }
    }
}
