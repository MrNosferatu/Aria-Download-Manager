import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt
import "../lib/OptionHelp.js" as OptionHelp
import "../lib/Layout.js" as Layout
import "../lib/Units.js" as Units

Item {
    id: tab

    property var service: null
    property var edits: ({})
    property string search: ""

    //: Simple shows the few options that decide how a download behaves;
    //: Advanced shows every option aria2 reports, the process, and the log.
    //: Remembered in the plugin's settings so the panel opens the way it was
    //: left, and read back through the service's settings view so the tab
    //: needs no plumbing of its own.
    readonly property bool advanced: (service ? service.cfg.settingsMode : "") === "advanced"

    //: Which engine downloads torrents, in one line.
    function torrentEngineText() {
        const qb = service ? service.qbittorrent : ({})
        if (!qb.wanted)
            return "aria2c"
        if (qb.running)
            return "qBittorrent " + (qb.version || "") + " · " + (qb.url || "")
        return "aria2c (qBittorrent unavailable: " + (qb.last_error || "not running") + ")"
    }

    function setMode(mode) {
        PluginService.savePluginData("ariaDownloadManager", "settingsMode", mode)
    }

    //: The log lives at the bottom of the Advanced page.
    //: `dms ipc call ariaDownloadManager tab log` opens this tab with the
    //: section unfolded and scrolls down to it.
    property bool logExpanded: false

    readonly property int scrollbarGutter: Layout.SCROLLBAR_GUTTER

    //: Simple: the settings the manager page shows, so both surfaces teach
    //: the same starting point, each with one grey line (board 8). Counts are
    //: steppers: [key, label, kind, help, minimum, maximum (0 = none)].
    readonly property var simpleOptions: [
        ["max-concurrent-downloads", "Downloads at once", "stepper", "The rest wait in the queue", 1, 0],
        ["max-connection-per-server", "Connections per server", "stepper", "More can be faster; some servers refuse", 1, 16],
        ["split", "Parts per download", "stepper", "Split one file into this many pieces", 1, 0],
        ["max-overall-download-limit", "Download speed limit", "text", "For everything together"],
        ["max-overall-upload-limit", "Upload speed limit", "text", "Torrents only"],
        ["download-only", "Torrents: download only", "bool", "Never seed; stop the moment a torrent finishes"],
        ["continue", "Resume interrupted downloads", "bool", "Pick up where a download left off after a restart"]
    ]

    // The groups board 19 names, which the chips above them jump to.
    readonly property var groups: [
        {
            "title": "Connection",
            "options": [["max-concurrent-downloads", "Downloads at once", "number"], ["max-connection-per-server", "Connections per server", "number"], ["split", "Parts per download", "number"], ["min-split-size", "Smallest part", "text"], ["optimize-concurrent-downloads", "Tune parallelism automatically", "bool"], ["max-tries", "Max retries", "number"], ["retry-wait", "Retry wait (s)", "number"], ["timeout", "Timeout (s)", "number"], ["connect-timeout", "Connect timeout (s)", "number"], ["max-file-not-found", "Not-found replies before giving up", "number"]]
        },
        {
            "title": "Speed",
            "options": [["max-overall-download-limit", "Download limit, all downloads", "text"], ["max-download-limit", "Download limit, each download", "text"], ["max-overall-upload-limit", "Upload limit, all downloads", "text"], ["max-upload-limit", "Upload limit, each download", "text"], ["lowest-speed-limit", "Give up below this speed", "text"]]
        },
        {
            "title": "Files",
            "options": [["file-allocation", "File allocation", "select:none,prealloc,trunc,falloc"], ["disk-cache", "Disk cache", "text"], ["continue", "Resume unfinished files", "bool"], ["allow-overwrite", "Overwrite existing files", "bool"], ["auto-file-renaming", "Rename duplicates automatically", "bool"], ["remote-time", "Keep the server's timestamps", "bool"]]
        },
        {
            "title": "HTTP",
            "options": [["user-agent", "User agent", "text"], ["referer", "Referer", "text"], ["http-accept-gzip", "Accept gzip", "bool"], ["all-proxy", "Proxy for every protocol", "text"], ["check-certificate", "Verify TLS certificates", "bool"]]
        },
        {
            "title": "BitTorrent",
            "options": [["download-only", "Download only, never seed", "bool"], ["follow-torrent", "Start downloaded torrents automatically", "bool"], ["bt-max-peers", "Peers per torrent", "number"], ["seed-ratio", "Seed until this ratio", "text"], ["seed-time", "Seed for this long (min)", "text"], ["enable-dht", "Use DHT", "bool"], ["bt-max-open-files", "Open files at once", "number"]]
        }
    ]

    readonly property var coveredKeys: {
        const out = []
        for (var i = 0; i < groups.length; i++)
            for (var j = 0; j < groups[i].options.length; j++)
                out.push(groups[i].options[j][0])
        return out
    }

    readonly property var advancedKeys: {
        const opts = service ? service.globalOptions : ({})
        const keys = Object.keys(opts).filter(k => coveredKeys.indexOf(k) === -1 && k !== "dir")
        keys.sort()
        return keys
    }

    //: aria2's option names carry their topic as a prefix, the only structure
    //: on offer beyond the curated set. Same rules and order as the manager page.
    readonly property var advancedRules: [
        ["BitTorrent", /^(bt-|dht|peer-|seed-|follow-torrent|listen-port|enable-peer-exchange|max-open-files)/],
        ["Metalink", /^(metalink|follow-metalink)/],
        ["HTTP", /^(http|header|user-agent|referer|content-disposition|use-head|enable-http)/],
        ["FTP", /^ftp/],
        ["Proxy", /proxy/],
        ["RPC", /^rpc/],
        ["Logging", /^(log|console-|quiet|summary-interval|show-|truncate-)/],
        ["Disk and files", /^(dir|disk-|file-|save-|no-file-|allow-|auto-file|conf-path|netrc|ca-cert|check-|piece-|hash-|realtime-|remove-control|force-save|auto-save)/],
        ["Transfer", /^(max-|min-|split|timeout|connect-timeout|retry|lowest-|stream-|uri-selector|server-stat|async-dns|conditional-get|always-resume|continue|deferred|reuse-uri|remote-time|parameterized|stop|pause|daemon|human-readable|no-conf|no-netrc|help)/]
    ]

    readonly property var advancedGroups: {
        const buckets = ({})
        for (const key of advancedKeys) {
            let title = "Other"
            for (var i = 0; i < advancedRules.length; i++) {
                if (advancedRules[i][1].test(key)) {
                    title = advancedRules[i][0]
                    break
                }
            }
            if (buckets[title] === undefined)
                buckets[title] = []
            buckets[title].push(key)
        }
        const out = []
        for (var j = 0; j < advancedRules.length; j++) {
            const t = advancedRules[j][0]
            if (buckets[t])
                out.push({ "title": t, "keys": buckets[t] })
        }
        if (buckets["Other"])
            out.push({ "title": "Other", "keys": buckets["Other"] })
        return out
    }

    //: How many of these options the search finds, for a group's "N of M".
    function hits(options) {
        let n = 0
        for (const o of options) {
            if (matches(o[0], o[1]))
                n++
        }
        return n
    }

    //: Every match on the page, for the search field's "N found".
    readonly property int searchHits: {
        if (!search)
            return 0
        let n = 0
        for (const g of groups)
            n += hits(g.options)
        return n + hits(advancedKeys.map(k => [k, k]))
    }

    //: "Every aria2 option" is long, so it stays folded unless asked for.
    property bool everyExpanded: false

    //: aria2's download folder as saved, and whether the field differs.
    readonly property string savedDir: {
        const opts = service ? service.globalOptions : ({})
        return opts["dir"] === undefined || opts["dir"] === null ? "" : String(opts["dir"])
    }
    readonly property bool dirEdited: dirField.text !== savedDir

    //: The folder chooser for a type's folder; zenity, as DirectoryField.
    function pickFolder(category) {
        const start = (routingFolders[category] || "").indexOf("/") === 0 ? routingFolders[category] : savedDir
        const args = ["zenity", "--file-selection", "--directory", "--title=Folder for " + routingLabels[category]]
        if (start)
            args.push("--filename=" + start.replace(/\/*$/, "/"))
        Proc.runCommand("ariaDownloadManager.pickDir.route." + category, args, (stdout, exitCode) => {
                            const path = stdout.trim()
                            if (exitCode === 0 && path)
                                tab.setRoutingFolder(category, path)
                        }, 0)
    }

    function matches(key, label) {
        if (!search)
            return true
        for (const needle of Fmt.searchForms(search)) {
            if (key.toLowerCase().indexOf(needle) >= 0 || label.toLowerCase().indexOf(needle) >= 0)
                return true
        }
        return false
    }

    //: Whether any option was touched since the last save; drives the save bar.
    //: `edits` is written in place, which notifies nothing, hence the flag.
    property bool optionsDirty: false
    readonly property bool dirty: optionsDirty || routingDirty

    function record(key, value) {
        edits[key] = value
        // Fields report their value when they are seeded too, so "touched"
        // is not enough: dirty means some edit differs from what is saved.
        const current = service ? service.globalOptions : ({})
        let differs = false
        for (const k in edits) {
            const original = current[k] === undefined || current[k] === null ? "" : String(current[k])
            if (!Units.same(edits[k], original)) {
                differs = true
                break
            }
        }
        optionsDirty = differs
    }

    //: Bumped by Discard: every field goes back to what is saved.
    property int generation: 0

    //: The wide window: a list of the page's sections on the left that jumps
    //: to each, the options on the right.
    property bool wide: false

    readonly property var sections: {
        const out = [["Download folder", simpleCard]]
        if (routingEnabled)
            out.push(["Where each type goes", routingCard])
        if (advanced) {
            for (let i = 0; i < groups.length; i++)
                out.push([groups[i].title, "group:" + i])
            out.push(["Every aria2 option", everySection])
            out.push(["aria2c process", procCard])
            out.push(["Event log", logCard])
        }
        return out
    }

    function jumpTo(target) {
        const item = typeof target === "string" ? groupRepeater.itemAt(Number(target.split(":")[1])) : target
        if (!item)
            return
        flick.contentY = Math.max(0, Math.min(item.y, flick.contentHeight - flick.height))
        if (item === logCard)
            tab.logExpanded = true
    }
    //: Why the last save failed, shown above the save bar with Retry; the
    //: edits stay so nothing typed is lost.
    property string saveError: ""

    function discard() {
        edits = ({})
        optionsDirty = false
        saveError = ""
        seedRouting()
        generation++
        dirField.text = Qt.binding(() => tab.savedDir)
    }

    function save() {
        saveError = ""
        const options = ({})
        const current = service.globalOptions
        var changed = 0
        for (const key in edits) {
            const original = current[key] === undefined || current[key] === null ? "" : String(current[key])
            // By value: "32M" and "33554432" are the same setting.
            if (!Units.same(edits[key], original)) {
                options[key] = String(edits[key])
                changed++
            }
        }
        if (tab.routingDirty) {
            service.saveRouting({
                                    "enabled": tab.routingEnabled,
                                    "folders": tab.routingFolders,
                                    "extensions": tab.routingExtensions
                                }, changed ? undefined : "Sorting saved", error => {
                                    if (error)
                                        tab.saveError = tab.plainSaveError(error)
                                    else
                                        tab.routingDirty = false
                                })
        } else if (!changed) {
            optionsDirty = false
            service.notice("Nothing changed")
            return
        }
        if (!changed) {
            optionsDirty = false
            return
        }
        service.saveOptions(options, "Applied " + changed + " change" + (changed === 1 ? "" : "s"), error => {
                                if (error) {
                                    tab.saveError = tab.plainSaveError(error)
                                    return
                                }
                                tab.edits = ({})
                                tab.optionsDirty = false
                            })
    }

    function plainSaveError(error) {
        const known = service.explainError(error)
        return "Couldn't save — " + (known ? known.why : error)
    }

    //: Unfold the log and go to it: it is the last thing on a long page.
    function revealLog() {
        if (!advanced)
            setMode("advanced")
        logExpanded = true
        scrollToLog.restart()
        if (service)
            service.requestedLog = false
    }

    //: The page keeps growing after the log is unfolded — the options load,
    //: the groups lay out — so for a moment the view stays pinned to the
    //: bottom as it grows, until the user scrolls or the page settles.
    property bool followLog: false

    Timer {
        id: scrollToLog

        interval: 60
        repeat: false
        onTriggered: {
            tab.followLog = true
            flick.contentY = Math.max(0, flick.contentHeight - flick.height)
            stopFollowing.restart()
        }
    }

    Timer {
        id: stopFollowing

        interval: 2000
        onTriggered: tab.followLog = false
    }

    Component.onCompleted: {
        if (!service)
            return
        service.loadOptions()
        service.loadRouting()
        seedRouting()
        if (service.requestedLog)
            revealLog()
    }

    //: Where downloads go by file type. Held here while it is edited, saved
    //: with everything else by the page's Save button.
    property bool routingEnabled: false
    property var routingFolders: ({})
    property var routingExtensions: ({})
    property bool routingDirty: false
    readonly property var routingCategories: ["archive", "music", "video", "image", "other"]
    readonly property var routingLabels: ({
            "archive": "Archives",
            "music": "Music",
            "video": "Video",
            "image": "Images",
            "other": "Everything else"
        })

    function seedRouting() {
        const data = service ? service.routing : null
        if (!data)
            return
        routingEnabled = data.enabled === true
        routingFolders = Object.assign({}, data.folders || ({}))
        routingExtensions = Object.assign({}, data.extensions || ({}))
        routingDirty = false
    }

    function setRoutingFolder(category, value) {
        const next = Object.assign({}, routingFolders)
        next[category] = value
        routingFolders = next
        routingDirty = true
    }

    function setRoutingExtensions(category, text) {
        const next = Object.assign({}, routingExtensions)
        next[category] = text.split(/[\s,]+/).filter(part => part.length > 0)
        routingExtensions = next
        routingDirty = true
    }

    Connections {
        target: tab.service
        function onRoutingChanged() {
            tab.seedRouting()
        }
    }

    Connections {
        target: tab.service
        function onRequestedLogChanged() {
            if (tab.service.requestedLog)
                tab.revealLog()
        }
    }

    // ---- header: Simple / Advanced and what the page holds -----------------
    Row {
        id: header

        width: parent.width - tab.scrollbarGutter
        height: 34
        spacing: 12

        Segmented {
            id: modeGroup

            anchors.verticalCenter: parent.verticalCenter
            model: ["Simple", "Advanced"]
            currentIndex: tab.advanced ? 1 : 0
            onPicked: index => tab.setMode(index === 1 ? "advanced" : "simple")
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, header.width - modeGroup.width - 12)
            text: tab.advanced ? "Every option aria2 reports, the process and its log"
                               : "The settings that decide how a download behaves"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
        }
    }

    Column {
        id: sectionNav

        anchors.top: header.bottom
        anchors.topMargin: 12
        anchors.left: parent.left
        width: 190
        visible: tab.wide
        spacing: 2

        Repeater {
            model: tab.wide ? tab.sections : []

            Rectangle {
                id: navItem

                required property var modelData

                width: sectionNav.width
                height: 36
                radius: 10
                color: navArea.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.06) : "transparent"

                StyledText {
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: navItem.modelData[0]
                    font.pixelSize: Theme.fontSizeSmall + 1
                    color: Theme.surfaceText
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                }

                MouseArea {
                    id: navArea

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: tab.jumpTo(navItem.modelData[1])
                }
            }
        }
    }

    //: A card of the page: a raised block with 16px of room inside.
    component Card: Rectangle {
        default property alias body: cardColumn.data
        property int padding: 16

        height: visible ? cardColumn.implicitHeight + padding * 2 : 0
        radius: 16
        color: Theme.surfaceContainer

        Column {
            id: cardColumn

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: parent.padding
        }
    }

    //: A card's heading: a bold title, and a figure or note on the right.
    component CardTitle: Item {
        property string text: ""
        property string note: ""
        property color noteColor: Theme.surfaceVariantText

        width: parent ? parent.width : 0
        height: 30

        StyledText {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: parent.text
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Bold
            color: Theme.surfaceText
        }

        StyledText {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: parent.note !== ""
            text: parent.note
            font.pixelSize: Theme.fontSizeSmall - 1
            color: parent.noteColor
        }
    }

    DankFlickable {
        id: flick

        anchors.top: header.bottom
        anchors.topMargin: 12
        anchors.bottom: errorBar.visible ? errorBar.top : (saveBar.visible ? saveBar.top : parent.bottom)
        anchors.bottomMargin: errorBar.visible || saveBar.visible ? 12 : 0
        anchors.left: sectionNav.visible ? sectionNav.right : parent.left
        anchors.leftMargin: sectionNav.visible ? 16 : 0
        anchors.right: parent.right
        clip: true
        contentHeight: content.implicitHeight
        contentWidth: width

        onContentHeightChanged: {
            if (tab.followLog)
                contentY = Math.max(0, contentHeight - height)
        }
        onMovementStarted: tab.followLog = false

        Column {
            id: content

            // The scrollbar is drawn over the flickable's right edge, so the
            // content stops short of it.
            width: parent.width - tab.scrollbarGutter
            spacing: 12

            // ---- advanced: find an option, or jump to a group --------------
            Column {
                width: parent.width
                visible: tab.advanced
                spacing: 10

                SearchPill {
                    id: searchField

                    width: parent.width
                    placeholderText: "Find an aria2 option"
                    trailingText: tab.searchHits + " found"
                    onTextChanged: tab.search = text.trim()
                }

                //: The window's section list already jumps; the chips are for
                //: the popout.
                Flow {
                    width: parent.width
                    visible: !tab.search && !tab.wide
                    spacing: 6

                    Repeater {
                        model: tab.groups

                        PillButton {
                            required property var modelData
                            required property int index

                            size: 32
                            kind: "outlined"
                            text: modelData.title
                            onClicked: tab.jumpTo("group:" + index)
                        }
                    }

                    PillButton {
                        size: 32
                        kind: "outlined"
                        text: "Every option"
                        onClicked: {
                            tab.everyExpanded = true
                            tab.jumpTo(everySection)
                        }
                    }
                }
            }

            // ---- the download folder, sorting, and (Simple) the basics -----
            Card {
                id: simpleCard

                width: content.width
                visible: !tab.advanced || !tab.search

                Column {
                    width: parent.width
                    spacing: 10
                    bottomPadding: 6

                    CardTitle {
                        text: "Download folder"
                        note: tab.dirEdited ? "●  edited" : ""
                        noteColor: Theme.primary
                    }

                    //: aria2's own download folder leads the card: every
                    //: folder below is relative to it, so the two belong
                    //: together. It is still an aria2 option, saved by Save.
                    DirectoryField {
                        id: dirField

                        objectName: "routeDefault"
                        width: parent.width
                        placeholderText: "Where downloads go"
                        text: tab.savedDir
                        onTextChanged: tab.record("dir", text)
                    }

                    Item {
                        width: parent.width
                        height: Math.max(32, sortText.implicitHeight)

                        StyledText {
                            id: sortText

                            anchors.left: parent.left
                            anchors.right: sortSwitch.left
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Sort into subfolders by type · " + tab.routingCategories.filter(c => c !== "other").map(c => tab.routingLabels[c]).join(", ")
                            wrapMode: Text.WordWrap
                            font.pixelSize: Theme.fontSizeSmall + 1
                            color: Theme.surfaceText
                        }

                        BoolSwitch {
                            id: sortSwitch

                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            checked: tab.routingEnabled
                            onToggled: value => {
                                tab.routingEnabled = value
                                tab.routingDirty = true
                            }
                        }
                    }
                }

                Repeater {
                    model: tab.advanced ? [] : tab.simpleOptions

                    OptionField {
                        id: simpleOption

                        required property var modelData

                        width: parent.width
                        divider: true
                        optionKey: simpleOption.modelData[0]
                        label: simpleOption.modelData[1]
                        kind: simpleOption.modelData[2]
                        description: simpleOption.modelData[3]
                        minimum: simpleOption.modelData[4] || 0
                        maximum: simpleOption.modelData[5] || 0
                        resetToken: tab.generation
                        original: {
                            const opts = tab.service ? tab.service.globalOptions : ({})
                            const raw = opts[simpleOption.modelData[0]]
                            return raw === undefined || raw === null ? "" : String(raw)
                        }
                        value: original
                        onEdited: (key, newValue) => tab.record(key, newValue)
                    }
                }
            }

            // ---- where each type goes (board 19) ----------------------------
            Card {
                id: routingCard

                width: content.width
                visible: tab.routingEnabled && (!tab.advanced || !tab.search)
                padding: 14

                Column {
                    width: parent.width
                    spacing: 8

                    CardTitle {
                        text: "Where each type goes"
                    }

                    //: One card per type: where it goes, and which extensions
                    //: count as it, as chips.
                    Repeater {
                        model: tab.routingEnabled ? tab.routingCategories : []

                        Rectangle {
                            id: categoryCard

                            required property var modelData

                            readonly property string category: modelData
                            readonly property var extensions: tab.routingExtensions[category] || []
                            property bool adding: false

                            width: parent.width
                            height: categoryColumn.implicitHeight + 24
                            radius: 12
                            color: Theme.surfaceContainerHigh

                            Column {
                                id: categoryColumn

                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: 12
                                spacing: 8

                                Item {
                                    width: parent.width
                                    height: 26

                                    DankIcon {
                                        id: categoryIcon

                                        anchors.left: parent.left
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: ({
                                                   "archive": "folder_zip",
                                                   "music": "music_note",
                                                   "video": "movie",
                                                   "image": "image",
                                                   "other": "draft"
                                               })[categoryCard.category] || "folder"
                                        size: 18
                                        color: Theme.primary
                                    }

                                    StyledText {
                                        id: categoryLabel

                                        anchors.left: categoryIcon.right
                                        anchors.leftMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: tab.routingLabels[categoryCard.category]
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.DemiBold
                                        color: Theme.surfaceText
                                    }

                                    //: "→ Video/": a relative name is a subfolder
                                    //: of the download folder; typed in place, or
                                    //: chosen with the folder button.
                                    Row {
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 4

                                        StyledText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: "→"
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.surfaceVariantText
                                        }

                                        TextInput {
                                            id: folderInput

                                            anchors.verticalCenter: parent.verticalCenter
                                            width: Math.min(Math.max(contentWidth + 2, folderHint.visible ? folderHint.implicitWidth : 8),
                                                            categoryCard.width - categoryLabel.x - categoryLabel.width - 90)
                                            horizontalAlignment: TextInput.AlignRight
                                            text: tab.routingFolders[categoryCard.category] || ""
                                            color: Theme.surfaceText
                                            selectByMouse: true
                                            clip: true
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            font.family: "monospace"
                                            onTextEdited: tab.setRoutingFolder(categoryCard.category, text.trim())

                                            StyledText {
                                                id: folderHint

                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                visible: folderInput.text.length === 0
                                                text: "download folder"
                                                font.pixelSize: Theme.fontSizeSmall - 1
                                                font.family: "monospace"
                                                color: Theme.surfaceVariantText
                                            }
                                        }

                                        DankActionButton {
                                            anchors.verticalCenter: parent.verticalCenter
                                            buttonSize: 26
                                            iconSize: 15
                                            iconName: "folder_open"
                                            iconColor: Theme.surfaceVariantText
                                            tooltipText: "Choose a folder for " + tab.routingLabels[categoryCard.category]
                                            onClicked: tab.pickFolder(categoryCard.category)
                                        }
                                    }
                                }

                                //: "Everything else" is whatever no list claims.
                                Flow {
                                    width: parent.width
                                    visible: categoryCard.category !== "other"
                                    spacing: 6

                                    Repeater {
                                        model: categoryCard.extensions

                                        Rectangle {
                                            id: extChip

                                            required property string modelData

                                            width: extRow.implicitWidth + 18
                                            height: 26
                                            radius: 13
                                            color: Theme.surfaceContainerHighest

                                            Row {
                                                id: extRow

                                                anchors.centerIn: parent
                                                spacing: 4

                                                StyledText {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    text: extChip.modelData
                                                    font.pixelSize: Theme.fontSizeSmall - 1
                                                    color: Theme.surfaceText
                                                }

                                                DankIcon {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    visible: extArea.containsMouse
                                                    name: "close"
                                                    size: 12
                                                    color: Theme.surfaceVariantText
                                                }
                                            }

                                            MouseArea {
                                                id: extArea

                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: tab.setRoutingExtensions(categoryCard.category,
                                                                                    categoryCard.extensions.filter(x => x !== extChip.modelData).join(" "))
                                            }
                                        }
                                    }

                                    //: A dashed "+ add" that turns into a box.
                                    Item {
                                        width: categoryCard.adding ? 80 : addLabel.implicitWidth + 20
                                        height: 26

                                        Canvas {
                                            anchors.fill: parent

                                            property color tint: Theme.outlineVariant
                                            property bool active: categoryCard.adding

                                            onTintChanged: requestPaint()
                                            onWidthChanged: requestPaint()
                                            onActiveChanged: requestPaint()

                                            onPaint: {
                                                const ctx = getContext("2d")
                                                ctx.reset()
                                                const r = (height - 1) / 2
                                                ctx.strokeStyle = active ? Theme.primary : tint
                                                ctx.lineWidth = 1
                                                ctx.setLineDash(active ? [] : [3, 3])
                                                ctx.beginPath()
                                                ctx.moveTo(r + 0.5, 0.5)
                                                ctx.lineTo(width - r - 0.5, 0.5)
                                                ctx.arc(width - r - 0.5, r + 0.5, r, -Math.PI / 2, Math.PI / 2)
                                                ctx.lineTo(r + 0.5, height - 0.5)
                                                ctx.arc(r + 0.5, r + 0.5, r, Math.PI / 2, Math.PI * 1.5)
                                                ctx.stroke()
                                            }
                                        }

                                        StyledText {
                                            id: addLabel

                                            anchors.centerIn: parent
                                            visible: !categoryCard.adding
                                            text: "+ add"
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.surfaceText
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            visible: !categoryCard.adding
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                categoryCard.adding = true
                                                extInput.forceActiveFocus()
                                            }
                                        }

                                        TextInput {
                                            id: extInput

                                            anchors.fill: parent
                                            anchors.leftMargin: 10
                                            anchors.rightMargin: 10
                                            verticalAlignment: TextInput.AlignVCenter
                                            visible: categoryCard.adding
                                            color: Theme.surfaceText
                                            clip: true
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            font.family: Theme.fontFamily
                                            onAccepted: {
                                                const added = text.trim().replace(/^\./, "").toLowerCase()
                                                if (added && categoryCard.extensions.indexOf(added) === -1)
                                                    tab.setRoutingExtensions(categoryCard.category, categoryCard.extensions.concat([added]).join(" "))
                                                text = ""
                                            }
                                            onActiveFocusChanged: if (!activeFocus) {
                                                                      text = ""
                                                                      categoryCard.adding = false
                                                                  }
                                            Keys.onEscapePressed: focus = false
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ---- advanced: the curated groups -------------------------------
            Repeater {
                id: groupRepeater

                model: tab.advanced ? tab.groups : []

                Card {
                    id: group

                    required property var modelData

                    width: content.width
                    padding: 14
                    visible: tab.hits(group.modelData.options) > 0

                    CardTitle {
                        text: group.modelData.title
                        note: tab.search ? tab.hits(group.modelData.options) + " of " + group.modelData.options.length : ""
                    }

                    Repeater {
                        model: group.modelData.options

                        OptionField {
                            id: option

                            required property var modelData
                            required property int index

                            width: parent.width
                            //: Only between rows that are shown.
                            divider: group.modelData.options.slice(0, index).some(o => tab.matches(o[0], o[1]))
                            optionKey: option.modelData[0]
                            label: option.modelData[1]
                            kind: option.modelData[2]
                            showKey: true
                            highlight: tab.search
                            resetToken: tab.generation
                            original: {
                                const opts = tab.service ? tab.service.globalOptions : ({})
                                const raw = opts[option.modelData[0]]
                                return raw === undefined || raw === null ? "" : String(raw)
                            }
                            value: original
                            visible: tab.matches(option.modelData[0], option.modelData[1])
                            height: visible ? implicitHeight : 0
                            onEdited: (key, newValue) => tab.record(key, newValue)
                        }
                    }
                }
            }

            // ---- advanced: every option aria2 reports -----------------------
            Card {
                id: everySection

                readonly property int found: tab.hits(tab.advancedKeys.map(k => [k, k]))
                readonly property bool open: tab.everyExpanded || tab.search !== ""

                width: content.width
                padding: 14
                visible: tab.advanced && (!tab.search || found > 0)

                Item {
                    width: parent.width
                    height: 30

                    DankIcon {
                        id: everyChevron

                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !tab.search
                        name: everySection.open ? "expand_less" : "expand_more"
                        size: 20
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        anchors.left: everyChevron.visible ? everyChevron.right : parent.left
                        anchors.leftMargin: everyChevron.visible ? 8 : 0
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Every aria2 option"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                    }

                    StyledText {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: tab.search ? String(everySection.found) : String(tab.advancedKeys.length)
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: !tab.search
                        cursorShape: Qt.PointingHandCursor
                        onClicked: tab.everyExpanded = !tab.everyExpanded
                    }
                }

                Repeater {
                    model: everySection.open ? tab.advancedGroups : []

                    Column {
                        id: advGroup

                        required property var modelData

                        width: parent.width
                        visible: {
                            if (!tab.search)
                                return true
                            const keys = advGroup.modelData.keys
                            for (var i = 0; i < keys.length; i++) {
                                if (tab.matches(keys[i], keys[i]))
                                    return true
                            }
                            return false
                        }

                        StyledText {
                            topPadding: 12
                            bottomPadding: 2
                            text: advGroup.modelData.title
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.DemiBold
                            color: Theme.surfaceVariantText
                        }

                        Repeater {
                            model: advGroup.modelData.keys

                            OptionField {
                                id: advancedOption

                                required property var modelData
                                required property int index

                                width: advGroup.width
                                divider: advGroup.modelData.keys.slice(0, index).some(k => tab.matches(k, k))
                                monoLabel: true
                                optionKey: advancedOption.modelData
                                label: advancedOption.modelData
                                kind: (original === "true" || original === "false") ? "bool" : "text"
                                description: OptionHelp.forKey(advancedOption.modelData) || "No description from aria2"
                                highlight: tab.search
                                resetToken: tab.generation
                                original: {
                                    const opts = tab.service ? tab.service.globalOptions : ({})
                                    const raw = opts[advancedOption.modelData]
                                    return raw === undefined || raw === null ? "" : String(raw)
                                }
                                value: original
                                visible: tab.matches(advancedOption.modelData, advancedOption.modelData)
                                height: visible ? implicitHeight : 0
                                onEdited: (key, newValue) => tab.record(key, newValue)
                            }
                        }
                    }
                }
            }

            // ---- advanced: the aria2c process -------------------------------
            Card {
                id: procCard

                readonly property var aria2: tab.service ? tab.service.aria2 : ({})
                readonly property string restarting: tab.service ? tab.service.restarting : ""
                property bool showDetails: false

                width: content.width
                padding: 14
                visible: tab.advanced && !tab.search

                //: Health first: a dot, the state in words, and version, pid
                //: and uptime on the right.
                Item {
                    width: parent.width
                    height: 28

                    Rectangle {
                        id: healthDot

                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: 8
                        height: 8
                        radius: 4
                        color: procCard.restarting ? Theme.warning : (procCard.aria2.running ? Theme.success : Theme.error)
                    }

                    StyledText {
                        anchors.left: healthDot.right
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: {
                            if (procCard.restarting === "aria2c")
                                return "aria2c restarting…"
                            if (procCard.restarting === "manager")
                                return "Manager restarting…"
                            return procCard.aria2.running ? "aria2c running" : "aria2c stopped"
                        }
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                    }

                    StyledText {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: {
                            const a = procCard.aria2
                            const bits = []
                            if (a.version)
                                bits.push(a.version)
                            if (a.pid)
                                bits.push("pid " + a.pid)
                            if (a.running && a.uptime)
                                bits.push("up " + Fmt.eta(a.uptime))
                            return bits.join(" · ")
                        }
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                    }
                }

                //: While a restart runs, its button turns into the wait and
                //: neither can be pressed again.
                Row {
                    topPadding: 6
                    spacing: 6

                    PillButton {
                        size: 32
                        kind: "outlined"
                        text: procCard.restarting === "aria2c" ? "Restarting…" : "Restart aria2c"
                        busy: procCard.restarting === "aria2c"
                        enabled: procCard.restarting === ""
                        onClicked: tab.service.restartAria2()
                    }

                    PillButton {
                        size: 32
                        kind: "outlined"
                        text: procCard.restarting === "manager" ? "Restarting…" : "Restart manager"
                        busy: procCard.restarting === "manager"
                        enabled: procCard.restarting === ""
                        onClicked: tab.service.restartManager()
                    }

                    PillButton {
                        size: 32
                        kind: "text"
                        trailingIcon: procCard.showDetails ? "expand_less" : "expand_more"
                        text: "Details"
                        onClicked: procCard.showDetails = !procCard.showDetails
                    }
                }

                Repeater {
                    model: {
                        if (!procCard.showDetails)
                            return []
                        const aria2 = procCard.aria2
                        const cfg = tab.service ? tab.service.serverConfig : null
                        return [["Managed", aria2.managed ? "Yes, started by the manager" : "No, external process"], ["RPC address", aria2.rpc_url || "—"], ["Restarts", String(aria2.restarts || 0)], ["Log file", aria2.log_file || "—"], ["Session file", aria2.session_file || "—"], ["Settings file", cfg && cfg.config_path ? cfg.config_path : "—"], ["Last error", aria2.last_error || "None"], ["Torrents", tab.torrentEngineText()]]
                    }

                    Row {
                        id: procRow

                        required property var modelData
                        required property int index

                        width: parent.width
                        height: 22
                        topPadding: index === 0 ? 8 : 0
                        spacing: 8

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 100
                            text: procRow.modelData[0]
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                        }

                        //: One line each: aria2's errors arrive with line breaks
                        //: and terminal colours in them.
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.max(0, parent.width - 108)
                            text: String(procRow.modelData[1]).replace(/\u001b\[[0-9;]*m/g, "").replace(/\s+/g, " ").trim()
                            wrapMode: Text.NoWrap
                            maximumLineCount: 1
                            font.pixelSize: Theme.fontSizeSmall - 1
                            font.family: "monospace"
                            color: procRow.modelData[0] === "Last error" && procRow.modelData[1] !== "None" ? Theme.error : Theme.surfaceText
                            elide: Text.ElideMiddle
                        }
                    }
                }
            }

            // ---- advanced: event log ----------------------------------------
            // Diagnostic material rather than a main view, so it holds no tab
            // of its own: it sits folded at the bottom, under the process card
            // it usually explains, saying how many errors it holds.
            Card {
                id: logCard

                readonly property var events: tab.service ? tab.service.events : []
                readonly property int errors: events.filter(ev => ev.level === "error").length

                width: content.width
                padding: 14
                visible: tab.advanced && !tab.search

                Item {
                    width: parent.width
                    height: 30

                    DankIcon {
                        id: logChevron

                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        name: tab.logExpanded ? "expand_less" : "expand_more"
                        size: 20
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        anchors.left: logChevron.right
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Event log"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: tab.logExpanded ? Font.Bold : Font.Medium
                        color: Theme.surfaceText
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: logCard.errors > 0
                            width: errorsLabel.implicitWidth + 16
                            height: 20
                            radius: 10
                            color: Theme.withAlpha(Theme.error, 0.16)

                            StyledText {
                                id: errorsLabel

                                anchors.centerIn: parent
                                text: logCard.errors + (logCard.errors === 1 ? " error" : " errors")
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.error
                            }
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: String(logCard.events.length)
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: tab.logExpanded = !tab.logExpanded
                    }
                }

                LogTab {
                    width: parent.width
                    visible: tab.logExpanded
                    height: visible ? 340 : 0
                    service: tab.service
                    compact: true
                }
            }
        }
    }

    // ---- a save that failed (board 19) ---------------------------------------
    //: Takes the save bar's place: says why, and offers Retry. The edits stay
    //: so nothing typed is lost.
    Rectangle {
        id: errorBar

        anchors.bottom: parent.bottom
        width: parent.width - tab.scrollbarGutter
        height: visible ? Math.max(50, errorLine.implicitHeight + 20) : 0
        visible: tab.saveError !== "" && tab.dirty
        radius: 14
        color: Theme.withAlpha(Theme.error, 0.08)
        border.width: 1
        border.color: Theme.withAlpha(Theme.error, 0.45)

        DankIcon {
            id: errorIcon

            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            name: "error"
            size: 18
            color: Theme.error
        }

        StyledText {
            id: errorLine

            anchors.left: errorIcon.right
            anchors.leftMargin: 10
            anchors.right: errorButtons.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: tab.saveError
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceText
        }

        Row {
            id: errorButtons

            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            PillButton {
                size: 34
                kind: "text"
                text: "Discard"
                onClicked: tab.discard()
            }

            PillButton {
                size: 34
                kind: "text"
                text: "Details"
                onClicked: tab.revealLog()
            }

            PillButton {
                size: 34
                kind: "filled"
                text: "Retry"
                onClicked: tab.save()
            }
        }
    }

    // ---- unsaved changes ---------------------------------------------------
    //: Replaces the always-visible Save button: it appears only once
    //: something was changed, and says so.
    Rectangle {
        id: saveBar

        anchors.bottom: parent.bottom
        width: parent.width - tab.scrollbarGutter
        height: 50
        visible: tab.dirty && !errorBar.visible
        radius: 16
        color: Theme.surfaceContainerHigh

        Rectangle {
            id: saveDot

            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            width: 6
            height: 6
            radius: 3
            color: Theme.primary
        }

        StyledText {
            anchors.left: saveDot.right
            anchors.leftMargin: 10
            anchors.right: saveNow.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: {
                let n = 0
                const current = tab.service ? tab.service.globalOptions : ({})
                for (const k in tab.edits) {
                    const original = current[k] === undefined || current[k] === null ? "" : String(current[k])
                    if (!Units.same(tab.edits[k], original))
                        n++
                }
                if (tab.routingDirty)
                    n++
                return n === 1 ? "1 unsaved change" : n + " unsaved changes"
            }
            font.pixelSize: Theme.fontSizeSmall + 1
            color: Theme.surfaceText
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
        }

        Row {
            id: saveNow

            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            PillButton {
                kind: "text"
                text: "Discard"
                onClicked: tab.discard()
            }

            PillButton {
                kind: "filled"
                text: "Save"
                onClicked: tab.save()
            }
        }
    }
}
