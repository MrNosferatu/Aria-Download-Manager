import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt

//: Adding downloads, in visible steps: the links (form), checking them
//: (busy), what they turned out to be (review), then each torrent's files
//: (torrent). Nothing starts before the review.
Column {
    id: panel

    property var service: null
    //: Simple: links, folder, start paused. Advanced: everything aria2 takes
    //: per download, in foldable groups. The same split as the manager page.
    property bool advanced: false
    property bool paused: false
    property bool mirrors: false
    //: Starts at the global setting; sent only when it differs from it.
    property bool downloadOnly: service ? service.downloadOnly : false
    property string stage: "form"
    property var formOptions: ({})
    property var formPosition: null
    //: The folder chosen on the form: "" leaves it to the manager.
    property string formDir: ""
    //: The links as checked: {url, mirrors, name, size, contentType,
    //: resumable, state: "ok" | "page" | "fail", error, suggested}.
    property var entries: []
    //: One line per link while checking: {key, label, state: "wait" | "ok" |
    //: "page" | "fail" | "torrent", detail}.
    property var checks: []
    //: Torrents added held, waiting for their file choice.
    property var held: []
    property var folderInfo: ({})
    property string reviewDir: ""
    property string torrentDirPath: ""

    readonly property string home: Quickshell.env("HOME") || ""

    signal submitted
    signal cancelled

    //: Fill the links box from outside (the empty list's paste button).
    function prefill(text) {
        stage = "form"
        urisField.text = text
    }

    Component.onCompleted: loadFolders("", "")
    onServiceChanged: loadFolders("", "")

    // ---- the form ----------------------------------------------------------
    function isTorrentLink(uri) {
        return /^magnet:/i.test(uri) || /\.torrent([?#]|$)/i.test(uri)
    }

    readonly property var parsedLinks: urisField.text.split("\n").map(line => line.trim()).filter(line => line.length > 0)

    //: Counted as it is typed, so a pasted block is checked at a glance:
    //: "3 links · 2 direct, 1 magnet".
    readonly property string linkSummary: {
        const n = parsedLinks.length
        if (!n)
            return ""
        let direct = 0, magnet = 0, torrent = 0, other = 0
        for (const u of parsedLinks) {
            if (/^magnet:/i.test(u))
                magnet++
            else if (isTorrentLink(u))
                torrent++
            else if (/^(https?|ftp|sftp):\/\/\S+$/i.test(u))
                direct++
            else
                other++
        }
        const parts = []
        if (direct)
            parts.push(direct + " direct")
        if (magnet)
            parts.push(magnet + (magnet === 1 ? " magnet" : " magnets"))
        if (torrent)
            parts.push(torrent + " torrent")
        if (other)
            parts.push(other + " not a link")
        return n + (n === 1 ? " link" : " links") + " · " + parts.join(", ")
    }

    function optionsPayload() {
        const options = ({})
        const put = (key, value) => {
            if (value && String(value).trim())
                options[key] = String(value).trim()
        }
        put("dir", formDir)
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

    //: How many fields of each advanced group hold something, for its header.
    readonly property int setFile: (formDir ? 1 : 0) + (outField.filled ? 1 : 0)
    readonly property int setConnection: (connField.filled ? 1 : 0) + (splitField.filled ? 1 : 0)
                                         + (minSplitField.value ? 1 : 0) + (limitField.value ? 1 : 0) + (mirrors ? 1 : 0)
    readonly property int setRequest: (refererField.filled ? 1 : 0) + (uaField.filled ? 1 : 0) + (cookieField.filled ? 1 : 0)
                                      + (proxyField.filled ? 1 : 0) + (headersField.text.trim() ? 1 : 0)
    readonly property int setCheck: (checksumField.filled ? 1 : 0) + (positionField.filled ? 1 : 0)
    readonly property int setTorrent: (torrentField.filled ? 1 : 0) + (service && downloadOnly !== service.downloadOnly ? 1 : 0)

    property var openGroups: ({
            "file": true
        })

    function toggleGroup(key) {
        const next = Object.assign({}, openGroups)
        next[key] = !next[key]
        openGroups = next
    }

    // ---- step 1: check what was given ----------------------------------
    function setCheckState(key, state, detail) {
        checks = checks.map(c => c.key === key ? Object.assign({}, c, {
                                                                "state": state,
                                                                "detail": detail || ""
                                                            }) : c)
    }

    function submit() {
        const uris = parsedLinks
        const torrent = torrentField.text.trim()
        if (!uris.length && !torrent) {
            ToastService.showError("Nothing to add", "Paste a link, or give a torrent file under Advanced.")
            return
        }
        const positionText = positionField.text.trim()
        formPosition = positionText === "" ? null : Number(positionText)
        formOptions = optionsPayload()

        const rows = []
        if (mirrors) {
            const plain = uris.filter(u => !isTorrentLink(u))
            if (plain.length)
                rows.push({
                              "key": plain[0],
                              "label": Fmt.shortLink(plain[0]) + (plain.length > 1 ? " · " + plain.length + " mirrors" : ""),
                              "state": "ok",
                              "detail": "one file"
                          })
            for (const u of uris.filter(u => isTorrentLink(u)))
                rows.push({
                              "key": u,
                              "label": Fmt.shortLink(u),
                              "state": "wait",
                              "detail": ""
                          })
        } else {
            for (const u of uris)
                rows.push({
                              "key": u,
                              "label": Fmt.shortLink(u),
                              "state": "wait",
                              "detail": ""
                          })
        }
        if (torrent)
            rows.push({
                          "key": torrent,
                          "label": Fmt.basename(torrent),
                          "state": "wait",
                          "detail": ""
                      })
        checks = rows
        stage = "busy"

        const found = []
        const heldNow = []
        let waiting = 1
        const finish = () => {
            if (--waiting > 0)
                return
            // Keep the order the links were given in.
            panel.entries = uris.map(u => found.find(f => f.url === u)).filter(f => !!f)
            panel.held = heldNow
            for (const gid of heldNow)
                panel.service.holdForChoice(gid)
            panel.next()
        }
        const hold = (keys, add) => {
            waiting++
            add((data, error) => {
                    if (error) {
                        const known = panel.service.explainError(error)
                        for (const k of keys)
                            panel.setCheckState(k, "fail", known ? known.why : error)
                        panel.service.showFailure("Couldn't add the torrent", error)
                    } else {
                        for (const gid of (data && data.gids) || [])
                            heldNow.push(gid)
                        for (const k of keys)
                            panel.setCheckState(k, "torrent", "files next")
                    }
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
            hold([torrent], done => Proc.runCommand("ariaDownloadManager.torrent", ["base64", "-w0", torrent], (stdout, exitCode) => {
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
                               "resumable": null,
                               "state": "ok"
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
                                        finish()
                                        return
                                    }
                                    const entry = {
                                        "url": url,
                                        "name": probe.name || Fmt.basename(url.split("?")[0]),
                                        "size": probe.size,
                                        "contentType": probe.contentType || "",
                                        "resumable": probe.resumable,
                                        "state": "ok",
                                        "error": ""
                                    }
                                    if (error || probe.error) {
                                        entry.state = "fail"
                                        const known = panel.service.explainError(error || probe.error)
                                        entry.error = known ? known.why : (error || probe.error)
                                    } else if (panel.looksLikePage(probe)) {
                                        entry.state = "page"
                                    }
                                    found.push(entry)
                                    panel.setCheckState(url, entry.state,
                                                        entry.state === "ok" ? (entry.size ? Fmt.bytes(entry.size) : "size unknown")
                                                                             : entry.state === "page" ? "a web page, not the file" : entry.error)
                                    // Where the manager would put it, for the review card.
                                    panel.service.get("/api/folders?name=" + encodeURIComponent(entry.name), (folders, ferr) => {
                                                          if (ferr || !folders)
                                                              return
                                                          panel.entries = panel.entries.map(e => e.url === url ? Object.assign({}, e, {
                                                                                                                                    "suggested": folders.suggested
                                                                                                                                }) : e)
                                                      })
                                    finish()
                                })
            }
        }
        finish()
    }

    //: Links that can start, links that cannot, then each held torrent;
    //: then back to the form.
    function next() {
        if (entries.length) {
            reviewDir = formOptions["dir"] || ""
            stage = "review"
        } else if (held.length) {
            torrentDirPath = formOptions["dir"] || ""
            torrentFolderFor = ""
            stage = "torrent"
        } else {
            urisField.text = ""
            torrentField.text = ""
            stage = "form"
            panel.submitted()
        }
    }

    //: The preset folders. With a name, `field` (a property name on the
    //: panel) starts at the folder for that file's type when the manager is
    //: not sorting by type itself.
    function loadFolders(name, field) {
        if (!service)
            return
        service.get("/api/folders?name=" + encodeURIComponent(name || ""), (data, error) => {
                        if (error || !data)
                            return
                        panel.folderInfo = data
                        if (field && !panel[field] && data.suggested && data.suggested !== data.base && !data.sorting)
                            panel[field] = data.suggested
                    })
    }

    // ---- step 2: plain links ------------------------------------------
    readonly property var okEntries: entries.filter(e => e.state === "ok")
    readonly property bool allFailed: entries.length > 0 && okEntries.length === 0

    function looksLikePage(entry) {
        if (entry.page)
            return true
        return /text\/html/i.test(entry.contentType || "") && /\.[a-z0-9]+$/i.test(entry.name || "")
            && !/\.(html?|xhtml|php|aspx?|jsp|txt|xml|json)$/i.test(entry.name || "")
    }

    //: Nothing plain to start, only torrents: go on to their files.
    function skipToTorrents() {
        entries = []
        next()
    }

    function skip(url) {
        entries = entries.filter(e => e.url !== url)
        if (!entries.length)
            next()
    }

    //: `anyway` starts the failed ones too — for servers that answer a check
    //: wrongly but serve the file to aria2.
    function startFiles(later, anyway) {
        const options = Object.assign({}, formOptions)
        const name = options["out"]
        delete options["out"]  // a name only ever belongs to a single file
        if (reviewDir)
            options["dir"] = reviewDir
        else
            delete options["dir"]
        const list = anyway ? entries : okEntries
        const gids = []
        let waiting = list.length
        let index = 0
        for (const entry of list) {
            const own = Object.assign({}, options)
            if (list.length === 1 && name)
                own["out"] = name
            service.request("POST", "/api/downloads", {
                                "uris": entry.mirrors || [entry.url],
                                "options": own,
                                "position": formPosition === null ? null : formPosition + index,
                                "paused": later || panel.paused,
                                "mirrors": !!entry.mirrors
                            }, (data, error) => {
                                if (error)
                                    panel.service.showFailure("Couldn't add " + entry.name, error)
                                else
                                    for (const gid of (data && data.gids) || [])
                                        gids.push(gid)
                                if (--waiting === 0)
                                    panel.reportStarted(gids, later || panel.paused)
                            })
            index++
        }
        entries = []
        next()
    }

    property var startedGids: []

    //: "Started 2 · 1 queued", read off the list once aria2 has placed them.
    function reportStarted(gids, held) {
        if (!gids.length)
            return
        if (held) {
            service.notice(gids.length === 1 ? "Added paused" : "Added " + gids.length + " paused")
            return
        }
        startedGids = gids
        startedReport.restart()
    }

    Timer {
        id: startedReport

        interval: 1500
        onTriggered: {
            const rows = panel.service.downloads.filter(d => panel.startedGids.indexOf(d.gid) >= 0)
            const running = rows.filter(d => d.status === "active" || d.status === "complete").length
            const queued = rows.filter(d => d.status === "waiting").length
            const parts = []
            if (running)
                parts.push("Started " + running)
            if (queued)
                parts.push(queued + " queued")
            panel.service.notice(parts.length ? parts.join(" · ") : "Added " + panel.startedGids.length)
        }
    }

    //: The torrents added held, as the review shows them beside the links:
    //: {name, meta, waiting}.
    readonly property var heldCards: {
        if (!service)
            return []
        return held.map(origin => {
                            const own = service.downloads.find(d => d.gid === origin) || null
                            const next = service.downloads.find(d => d.following === origin) || null
                            const row = next || own
                            if (!row)
                                return {
                                    "name": "Torrent",
                                    "meta": "Adding…",
                                    "waiting": true
                                }
                            if (row.isMetadata)
                                return {
                                    "name": row.name || "Magnet link",
                                    "meta": "Getting the file list · " + (row.connections || 0) + " peers",
                                    "waiting": true
                                }
                            return {
                                "name": row.name,
                                "meta": (row.numFiles || 0) + (row.numFiles === 1 ? " file · " : " files · ") + Fmt.bytes(row.total) + " · pick files next",
                                "waiting": false
                            }
                        })
    }

    // ---- step 3: held torrents ----------------------------------------
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
    //: The gid whose folder suggestion is loaded, so it is asked once per torrent.
    property string torrentFolderFor: ""

    onReviewReadyChanged: {
        if (!reviewReady || stage !== "torrent" || torrentFolderFor === reviewGid)
            return
        torrentFolderFor = reviewGid
        // What the torrent mostly is: its biggest file picks the folder.
        service.get("/api/download/" + reviewGid, (data, error) => {
                        const files = (data && data.files) || []
                        let biggest = null
                        for (const f of files)
                            if (!biggest || Number(f.length) > Number(biggest.length))
                                biggest = f
                        panel.loadFolders(biggest ? Fmt.basename(biggest.path) : (reviewRow ? reviewRow.name : ""), "torrentDirPath")
                    })
    }

    function torrentDone() {
        service.releaseHold(held[0])
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
        for (const gid of held) {
            service.releaseHold(gid)
            service.request("DELETE", "/api/download/" + gid + "?force=true&purge=true&delete_files=true", null, () => {})
        }
        if (reviewGid && held.length && reviewGid !== held[0])
            service.request("DELETE", "/api/download/" + reviewGid + "?force=true&purge=true&delete_files=true", null, () => {})
        entries = []
        held = []
        stage = "form"
    }

    spacing: 12

    //: A foldable heading for one group of advanced fields, with how many of
    //: them hold something (board 16). Inline, so it is told its state rather
    //: than reading the panel's.
    component GroupHeader: Item {
        id: header

        property string title: ""
        property string icon: ""
        property int count: 0
        property bool open: false

        signal toggled

        width: parent ? parent.width : 0
        height: 28

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: header.icon
                size: 16
                color: Theme.primary
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: header.title
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.DemiBold
                color: Theme.primary
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: header.count > 0
                text: "· " + header.count + " set"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }

        DankIcon {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            name: header.open ? "expand_less" : "expand_more"
            size: 18
            color: Theme.surfaceVariantText
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: header.toggled()
        }
    }

    //: A label with its switch at the far end, the board's settings line.
    component SwitchLine: Item {
        id: line

        property string label: ""
        property bool checked: false

        signal toggled(bool value)

        width: parent ? parent.width : 0
        height: 36

        StyledText {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: line.label
            font.pixelSize: Theme.fontSizeSmall + 1
            color: Theme.surfaceText
        }

        BoolSwitch {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: line.checked
            onToggled: value => line.toggled(value)
        }
    }

    //: An icon that turns while something is being waited on.
    component Turning: DankIcon {
        id: spinner

        property bool turning: true

        name: "progress_activity"
        size: 18
        color: Theme.surfaceVariantText

        RotationAnimation on rotation {
            running: spinner.turning
            loops: Animation.Infinite
            from: 0
            to: 360
            duration: 1000
        }
    }

    //: A small label above a field or a group of chips.
    component FieldLabel: StyledText {
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    // ======== form (boards 5, 16) =========================================
    Column {
        width: parent.width
        visible: panel.stage === "form"
        spacing: 12

        Item {
            width: parent.width
            height: 34

            StyledText {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Add downloads"
                font.pixelSize: Theme.fontSizeMedium + 1
                font.weight: Font.Bold
                color: Theme.surfaceText
            }

            Segmented {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                model: ["Simple", "Advanced"]
                currentIndex: panel.advanced ? 1 : 0
                onPicked: index => panel.advanced = index === 1
            }
        }

        Column {
            width: parent.width
            spacing: 6

            FieldLabel {
                visible: !panel.advanced
                text: "Links, one per line"
            }

            MultiLineField {
                id: urisField

                width: parent.width
                minimumHeight: panel.advanced ? 64 : 120
                mono: true
                sunken: true
                placeholderText: "https://… or magnet:?xt=…"
                onAccepted: panel.submit()
            }

            StyledText {
                width: parent.width
                visible: panel.linkSummary !== ""
                text: panel.linkSummary
                font.pixelSize: Theme.fontSizeSmall
                color: panel.linkSummary.indexOf("not a link") >= 0 ? Theme.warning : Theme.surfaceVariantText
            }
        }

        // ---- simple: the folder as one tap ----
        Column {
            width: parent.width
            visible: !panel.advanced
            spacing: 6

            FieldLabel {
                text: "Save to"
            }

            FolderChips {
                width: parent.width
                info: panel.folderInfo
                home: panel.home
                path: panel.formDir
                onChosen: chosenPath => panel.formDir = chosenPath
            }
        }

        // ---- advanced: grouped, foldable ----
        Column {
            width: parent.width
            visible: panel.advanced
            spacing: 8

            GroupHeader {
                title: "File"
                icon: "folder"
                count: panel.setFile
                open: !!panel.openGroups.file
                onToggled: panel.toggleGroup("file")
            }

            Column {
                width: parent.width
                visible: !!panel.openGroups.file
                spacing: 8

                FolderChips {
                    width: parent.width
                    info: panel.folderInfo
                    home: panel.home
                    path: panel.formDir
                    onChosen: chosenPath => panel.formDir = chosenPath
                }

                AddField {
                    id: outField

                    width: parent.width
                    label: "Save as"
                    placeholderText: "Save as (one file only)"
                }
            }

            GroupHeader {
                title: "Connection"
                icon: "speed"
                count: panel.setConnection
                open: !!panel.openGroups.connection
                onToggled: panel.toggleGroup("connection")
            }

            Column {
                width: parent.width
                visible: !!panel.openGroups.connection
                spacing: 8

                Grid {
                    width: parent.width
                    columns: 2
                    columnSpacing: 8
                    rowSpacing: 8

                    AddField {
                        id: connField

                        width: (parent.width - 8) / 2
                        placeholderText: "Connections per server"
                        suffix: "connections"
                    }

                    AddField {
                        id: splitField

                        width: (parent.width - 8) / 2
                        placeholderText: "Parts"
                        suffix: "parts"
                    }

                    UnitField {
                        id: limitField

                        width: (parent.width - 8) / 2
                        kind: "speed"
                        label: "Speed limit"
                        placeholderText: "Speed limit: none"
                    }

                    UnitField {
                        id: minSplitField

                        width: (parent.width - 8) / 2
                        kind: "size"
                        label: "Smallest part"
                        placeholderText: "Smallest part: 1 MiB"
                    }
                }

                SwitchLine {
                    label: "Links are mirrors of one file"
                    checked: panel.mirrors
                    onToggled: value => panel.mirrors = value
                }
            }

            GroupHeader {
                title: "Request"
                icon: "http"
                count: panel.setRequest
                open: !!panel.openGroups.request
                onToggled: panel.toggleGroup("request")
            }

            Column {
                width: parent.width
                visible: !!panel.openGroups.request
                spacing: 8

                Grid {
                    width: parent.width
                    columns: 2
                    columnSpacing: 8
                    rowSpacing: 8

                    AddField {
                        id: refererField

                        width: (parent.width - 8) / 2
                        label: "Referer"
                    }

                    AddField {
                        id: uaField

                        width: (parent.width - 8) / 2
                        label: "User agent"
                    }

                    AddField {
                        id: cookieField

                        width: (parent.width - 8) / 2
                        label: "Cookies"
                    }

                    AddField {
                        id: proxyField

                        width: (parent.width - 8) / 2
                        label: "Proxy"
                    }
                }

                MultiLineField {
                    id: headersField

                    width: parent.width
                    minimumHeight: 48
                    placeholderText: "Extra headers, one per line"
                }
            }

            GroupHeader {
                title: "Check & queue"
                icon: "verified"
                count: panel.setCheck
                open: !!panel.openGroups.check
                onToggled: panel.toggleGroup("check")
            }

            Grid {
                width: parent.width
                visible: !!panel.openGroups.check
                columns: 2
                columnSpacing: 8
                rowSpacing: 8

                AddField {
                    id: checksumField

                    width: (parent.width - 8) / 2
                    label: "Checksum"
                    placeholderText: "Checksum (sha-256=…)"
                }

                AddField {
                    id: positionField

                    width: (parent.width - 8) / 2
                    label: "Queue position"
                    placeholderText: "Queue position (blank: at the end)"
                }
            }

            GroupHeader {
                title: "Torrent & metalink"
                icon: "hub"
                count: panel.setTorrent
                open: !!panel.openGroups.torrent
                onToggled: panel.toggleGroup("torrent")
            }

            Column {
                width: parent.width
                visible: !!panel.openGroups.torrent
                spacing: 8

                AddField {
                    id: torrentField

                    width: parent.width
                    label: "File"
                    placeholderText: "Torrent or metalink file path"
                    iconName: "attach_file"
                }

                SwitchLine {
                    label: "Download only, never seed"
                    checked: panel.downloadOnly
                    onToggled: value => panel.downloadOnly = value
                }
            }
        }

        SwitchLine {
            label: "Start paused"
            checked: panel.paused
            onToggled: value => panel.paused = value
        }

        //: Says what happens next: nothing starts until the review.
        Row {
            anchors.right: parent.right
            spacing: 8

            PillButton {
                size: 40
                kind: "text"
                text: "Cancel"
                onClicked: panel.cancelled()
            }

            PillButton {
                size: 40
                kind: "filled"
                text: "Check links"
                trailingIcon: "arrow_forward"
                onClicked: panel.submit()
            }
        }
    }

    // ======== checking (board 16) =========================================
    //: One line per link, each settling on its own as its answer arrives.
    Column {
        width: parent.width
        visible: panel.stage === "busy"
        spacing: 8

        StyledText {
            text: "Checking " + panel.checks.length + (panel.checks.length === 1 ? " link…" : " links…")
            font.pixelSize: Theme.fontSizeMedium + 1
            font.weight: Font.Bold
            color: Theme.surfaceText
        }

        Repeater {
            model: panel.checks

            Rectangle {
                id: checkLine

                required property var modelData

                readonly property bool bad: modelData.state === "page" || modelData.state === "fail"

                width: parent.width
                height: 40
                radius: 12
                color: Theme.surfaceContainerHigh

                Turning {
                    id: checkIcon

                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    turning: checkLine.modelData.state === "wait"
                    size: 18
                    name: {
                        switch (checkLine.modelData.state) {
                        case "ok":
                            return "check_circle"
                        case "torrent":
                            return "hub"
                        case "page":
                            return "web"
                        case "fail":
                            return "error"
                        default:
                            return "progress_activity"
                        }
                    }
                    color: {
                        switch (checkLine.modelData.state) {
                        case "ok":
                            return Theme.success
                        case "torrent":
                            return Theme.primary
                        case "page":
                        case "fail":
                            return Theme.error
                        default:
                            return Theme.surfaceVariantText
                        }
                    }
                }

                StyledText {
                    anchors.left: checkIcon.right
                    anchors.leftMargin: 10
                    anchors.right: checkDetail.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: checkLine.modelData.label
                    font.pixelSize: Theme.fontSizeSmall + 1
                    font.weight: Font.DemiBold
                    color: Theme.surfaceText
                    elide: Text.ElideMiddle
                    wrapMode: Text.NoWrap
                }

                StyledText {
                    id: checkDetail

                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, parent.width * 0.4)
                    text: checkLine.modelData.state === "wait" ? "asking…" : checkLine.modelData.detail
                    font.pixelSize: Theme.fontSizeSmall
                    color: checkLine.bad ? Theme.error : Theme.surfaceVariantText
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignRight
                }
            }
        }

        Row {
            anchors.right: parent.right
            spacing: 8

            PillButton {
                size: 36
                kind: "text"
                text: "Back"
                onClicked: panel.back()
            }

            PillButton {
                size: 36
                kind: "outlined"
                text: "Download"
                enabled: false
            }
        }
    }

    // ======== review (board 5; every link failed: board 16) ===============
    Column {
        width: parent.width
        visible: panel.stage === "review" && !panel.allFailed
        spacing: 10

        StyledText {
            text: panel.okEntries.length === 1 || panel.okEntries.length === 0 ? "Ready to download" : panel.okEntries.length + " ready to download"
            font.pixelSize: Theme.fontSizeMedium + 1
            font.weight: Font.Bold
            color: Theme.surfaceText
        }

        Repeater {
            model: panel.entries

            Rectangle {
                id: card

                required property var modelData

                readonly property bool ok: modelData.state === "ok"
                //: Where it will actually land: the folder picked, else the
                //: type's folder when the manager sorts, else the download folder.
                readonly property string dest: Fmt.homePath(panel.reviewDir || (panel.folderInfo.sorting ? modelData.suggested : panel.folderInfo.base) || "", panel.home)

                width: parent.width
                height: cardColumn.implicitHeight + 24
                radius: 14
                color: ok ? Theme.surfaceContainerHigh : Theme.withAlpha(Theme.error, 0.08)
                border.width: ok ? 0 : 1
                border.color: Theme.withAlpha(Theme.error, 0.4)

                Column {
                    id: cardColumn

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 10

                    Item {
                        width: parent.width
                        height: 40

                        Rectangle {
                            id: cardTile

                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: 40
                            height: 40
                            radius: 12
                            color: card.ok ? Theme.surfaceContainerHighest : Theme.withAlpha(Theme.error, 0.14)

                            DankIcon {
                                anchors.centerIn: parent
                                name: card.modelData.state === "page" ? "web" : (card.ok ? Fmt.kindIcon(card.modelData.name, false, false) : "link_off")
                                size: 20
                                color: card.ok ? Theme.primary : Theme.error
                            }
                        }

                        Row {
                            id: resumeNote

                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: card.ok && card.modelData.resumable !== null && card.modelData.resumable !== undefined
                            spacing: 3

                            DankIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: card.modelData.resumable ? "check" : "block"
                                size: 14
                                color: card.modelData.resumable ? Theme.success : Theme.warning
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: card.modelData.resumable ? "Resumable" : "Can't resume"
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.weight: Font.DemiBold
                                color: card.modelData.resumable ? Theme.success : Theme.warning
                            }
                        }

                        Column {
                            anchors.left: cardTile.right
                            anchors.leftMargin: 12
                            anchors.right: resumeNote.visible ? resumeNote.left : parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            StyledText {
                                width: parent.width
                                text: card.modelData.name + (card.modelData.mirrors ? " · " + card.modelData.mirrors.length + " mirrors" : "")
                                font.pixelSize: Theme.fontSizeSmall + 1
                                font.weight: Font.DemiBold
                                color: Theme.surfaceText
                                elide: Text.ElideMiddle
                                wrapMode: Text.NoWrap
                            }

                            StyledText {
                                width: parent.width
                                text: {
                                    const d = card.modelData
                                    if (d.state === "page")
                                        return "Got a web page, not the file"
                                    if (d.state === "fail")
                                        return Fmt.label(d.error || "couldn't reach it")
                                    return (d.size ? Fmt.bytes(d.size) : "Size unknown") + " · " + Fmt.kindLabel(d.name, d.contentType)
                                            + (card.dest ? " · → " + card.dest : "")
                                }
                                font.pixelSize: Theme.fontSizeSmall
                                color: card.ok ? Theme.surfaceVariantText : Theme.error
                                elide: Text.ElideRight
                                wrapMode: Text.NoWrap
                            }
                        }
                    }

                    StyledText {
                        width: parent.width
                        visible: card.modelData.state === "page"
                        wrapMode: Text.WordWrap
                        text: "Usually a login, a captcha or a one-time link. Download it in a browser instead."
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    Row {
                        visible: !card.ok
                        spacing: 6

                        PillButton {
                            visible: card.modelData.state === "page"
                            size: 32
                            kind: "outlined"
                            text: "Open in browser"
                            onClicked: Quickshell.execDetached(["xdg-open", card.modelData.url])
                        }

                        PillButton {
                            size: 32
                            kind: "text"
                            text: "Skip this link"
                            onClicked: panel.skip(card.modelData.url)
                        }
                    }
                }
            }
        }

        //: Torrents in the batch wait for their file list; their files come
        //: after the links.
        Repeater {
            model: panel.heldCards

            Rectangle {
                id: heldCard

                required property var modelData

                width: parent.width
                height: 64
                radius: 14
                color: Theme.surfaceContainerHigh

                Rectangle {
                    id: heldTile

                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    width: 40
                    height: 40
                    radius: 12
                    color: Theme.surfaceContainerHighest

                    DankIcon {
                        anchors.centerIn: parent
                        name: "hub"
                        size: 20
                        color: Theme.surfaceVariantText
                    }
                }

                Column {
                    anchors.left: heldTile.right
                    anchors.leftMargin: 12
                    anchors.right: heldSpin.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    StyledText {
                        width: parent.width
                        text: heldCard.modelData.name
                        font.pixelSize: Theme.fontSizeSmall + 1
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                        wrapMode: Text.NoWrap
                        elide: Text.ElideMiddle
                    }

                    StyledText {
                        width: parent.width
                        text: heldCard.modelData.meta
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                    }
                }

                Turning {
                    id: heldSpin

                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    visible: heldCard.modelData.waiting
                    turning: visible
                }
            }
        }

        Item {
            width: parent.width
            height: 40

            PillButton {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                size: 40
                kind: "text"
                icon: "arrow_back"
                text: "Back"
                onClicked: panel.back()
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                PillButton {
                    size: 40
                    kind: "outlined"
                    text: "Queue"
                    visible: panel.okEntries.length > 0
                    onClicked: panel.startFiles(true, false)
                }

                //: Counts what will actually start.
                PillButton {
                    size: 40
                    kind: "filled"
                    text: panel.okEntries.length > 0 ? "Download " + panel.okEntries.length : "Next"
                    onClicked: panel.okEntries.length > 0 ? panel.startFiles(false, false) : panel.skipToTorrents()
                }
            }
        }
    }

    Rectangle {
        width: parent.width
        visible: panel.stage === "review" && panel.allFailed
        height: failColumn.implicitHeight + 28
        radius: 14
        color: "transparent"
        border.width: 1
        border.color: Theme.withAlpha(Theme.error, 0.4)

        Column {
            id: failColumn

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 14
            spacing: 8

            Row {
                spacing: 8

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "link_off"
                    size: 20
                    color: Theme.error
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "None of these can be downloaded"
                    font.pixelSize: Theme.fontSizeMedium + 1
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                }
            }

            Repeater {
                model: panel.entries

                Rectangle {
                    id: failLine

                    required property var modelData

                    width: failColumn.width
                    height: 40
                    radius: 10
                    color: Theme.surfaceContainerHigh

                    StyledText {
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.right: failReason.left
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: Fmt.shortLink(failLine.modelData.url)
                        font.pixelSize: Theme.fontSizeSmall + 1
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                        wrapMode: Text.NoWrap
                        elide: Text.ElideMiddle
                    }

                    StyledText {
                        id: failReason

                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, parent.width * 0.45)
                        text: failLine.modelData.state === "page" ? "a web page" : (failLine.modelData.error || "no answer")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.error
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignRight
                    }
                }
            }

            Row {
                topPadding: 2
                spacing: 6

                PillButton {
                    size: 32
                    kind: "outlined"
                    text: "Edit links"
                    onClicked: panel.back()
                }

                //: For servers that answer a check wrongly but serve aria2 fine.
                PillButton {
                    size: 32
                    kind: "text"
                    text: "Add anyway"
                    onClicked: panel.startFiles(false, true)
                }
            }
        }
    }

    // ======== torrent files (board 5) =====================================
    Column {
        width: parent.width
        visible: panel.stage === "torrent"
        spacing: 10

        StyledText {
            width: parent.width
            text: panel.reviewRow ? panel.reviewRow.name : "Torrent"
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            font.pixelSize: Theme.fontSizeMedium + 1
            font.weight: Font.Bold
            color: Theme.surfaceText
        }

        Column {
            width: parent.width
            visible: panel.reviewReady
            spacing: 6

            FieldLabel {
                text: "Save to"
            }

            FolderChips {
                width: parent.width
                info: panel.folderInfo
                home: panel.home
                path: panel.torrentDirPath
                onChosen: chosenPath => panel.torrentDirPath = chosenPath
            }
        }

        Row {
            visible: !panel.reviewReady
            spacing: 8

            Turning {
                anchors.verticalCenter: parent.verticalCenter
                turning: panel.stage === "torrent" && !panel.reviewReady
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Getting the file list from peers…" + (panel.reviewRow && panel.reviewRow.connections ? " · " + panel.reviewRow.connections + " connected" : "")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }

        PillButton {
            anchors.right: parent.right
            visible: !panel.reviewReady
            size: 40
            kind: "text"
            text: "Cancel"
            onClicked: panel.cancelTorrent()
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
                extraOptions: panel.torrentDirPath ? ({
                                                          "dir": panel.torrentDirPath
                                                      }) : ({})
                onStarted: panel.torrentDone()
                onCancelRequested: panel.cancelTorrent()
            }
        }
    }
}
