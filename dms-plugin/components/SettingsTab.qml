import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt
import "../lib/OptionHelp.js" as OptionHelp
import "../lib/Layout.js" as Layout
import "../lib/Units.js" as Units
import "../lib/Vpn.js" as Vpn

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
        ["max-concurrent-downloads", "Downloads at once", "stepper", "How many run at once; the rest wait in the queue", 1, 0],
        ["max-connection-per-server", "Connections per server", "stepper", "Up to 16. More can be faster; some servers allow only a few", 1, 16],
        ["split", "Parts per download", "stepper", "One file is fetched in this many pieces at once", 1, 0],
        ["max-overall-download-limit", "Download speed limit", "text", "Across every download. Blank means no limit"],
        ["max-overall-upload-limit", "Upload speed limit", "text", "Torrents only. Blank means no limit"],
        ["download-only", "Torrents: download only", "bool", "Never seed: at most 1 B/s up while downloading, and stop the moment it finishes"],
        ["continue", "Resume unfinished files", "bool", "Pick up a partial file where it stopped instead of starting over"]
    ]

    // The groups board 19 names, which the chips above them jump to.
    readonly property var groups: [
        {
            "title": "Connection",
            "options": [["max-concurrent-downloads", "Downloads at once", "number"], ["max-connection-per-server", "Connections per server", "number"], ["split", "Parts per download", "number"], ["min-split-size", "Smallest part", "text"], ["optimize-concurrent-downloads", "Tune parallelism automatically", "bool"], ["max-tries", "Attempts (0 = unlimited)", "number"], ["retry-wait", "Retry wait (s)", "number"], ["timeout", "Timeout (s)", "number"], ["connect-timeout", "Connect timeout (s)", "number"], ["max-file-not-found", "Not-found replies before giving up", "number"]]
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

    //: One search for every setting, aria2's options and the manager's own
    //: cards alike, in both modes. Simple searches what Simple shows and
    //: offers "N more in Advanced"; switching modes is the user's choice,
    //: since it rebuilds the fields.
    readonly property bool searching: search !== ""
    //: Matches only Advanced shows, for Simple's "N more in Advanced".
    readonly property int advancedOnlyHits: {
        if (!search || advanced)
            return 0
        const simpleKeys = simpleOptions.map(o => o[0])
        let n = 0
        for (const g of groups)
            n += hits(g.options.filter(o => simpleKeys.indexOf(o[0]) < 0))
        n += hits(advancedKeys.map(k => [k, k]))
        return n + [procCardFound, logCardFound].filter(f => f).length
    }

    function cardMatches(words) {
        if (!search)
            return true
        const text = words.join(" ").toLowerCase()
        return Fmt.searchForms(search).some(needle => text.indexOf(needle) >= 0)
    }

    readonly property bool folderCardFound: cardMatches(["Download folder", "dir", "Sort into subfolders by type",
                                                         "sorting", "Archives Music Video Images"])
    readonly property bool routingCardFound: cardMatches(["Where each type goes", "sorting", "extensions"]
                                                         .concat(routingCategories.map(c => routingLabels[c] + " " + (routingFolders[c] || "")))
                                                         .concat(routingCategories.map(c => (routingExtensions[c] || []).join(" "))))
    readonly property bool vpnCardFound: cardMatches(["VPN for downloads", "WireGuard", "Proton", "wireproxy", "Server",
                                                      "Config folder", "Sites that use the VPN", "tunnel", "proxy"].concat(vpnSites))
    readonly property bool procCardFound: cardMatches(["aria2c process", "Restart aria2c", "pid", "version", "RPC"])
    readonly property bool logCardFound: cardMatches(["Event log", "errors", "log"])

    //: Every match shown, for the search field's "N found".
    readonly property int searchHits: {
        if (!search)
            return 0
        let n = [folderCardFound, routingEnabled && routingCardFound, vpnCardFound].filter(f => f).length
        if (!advanced)
            return n + hits(simpleOptions)
        for (const g of groups)
            n += hits(g.options)
        n += [procCardFound, logCardFound].filter(f => f).length
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

    //: How many options differ from what is saved, and whether any do; they
    //: drive the save bar. `edits` is written in place, which notifies
    //: nothing, so these are counted here, not in a binding over `edits`.
    property int optionChanges: 0
    property bool optionsDirty: false
    readonly property bool dirty: optionsDirty || routingDirty || vpnDirty
    //: What the save bar counts: each option, and each card as one.
    readonly property int changeTotal: optionChanges + (routingDirty ? 1 : 0) + (vpnDirty ? 1 : 0)

    function record(key, value) {
        edits[key] = value
        recount()
    }

    //: Fields report their value when they are seeded too, so "touched" is
    //: not enough: an option counts while its edit differs from what is saved.
    function recount() {
        const current = service ? service.globalOptions : ({})
        let n = 0
        for (const k in edits) {
            const original = current[k] === undefined || current[k] === null ? "" : String(current[k])
            if (!Units.same(edits[k], original))
                n++
        }
        optionChanges = n
        optionsDirty = n > 0
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
        out.push(["VPN for downloads", vpnCard])
        if (advanced) {
            for (let i = 0; i < groups.length; i++)
                out.push([groups[i].title, "group:" + i])
            out.push(["Every aria2 option", everySection])
            out.push(["aria2c process", procCard])
            out.push(["Event log", logCard])
        }
        // While searching, only the sections that hold a match.
        if (!searching)
            return out
        return out.filter(s => typeof s[1] === "string" ? hits(groups[Number(s[1].split(":")[1])].options) > 0 : s[1].visible)
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
        recount()
        saveError = ""
        seedRouting()
        seedVpn()
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
        if (tab.vpnDirty)
            service.saveVpn({
                                "enabled": tab.vpnEnabled,
                                "folder": tab.vpnFolder,
                                "server": tab.vpnServer,
                                "sites": tab.vpnSites
                            }, changed || tab.routingDirty ? undefined : "VPN saved", error => {
                                if (error)
                                    tab.saveError = tab.plainSaveError(error)
                                else
                                    tab.vpnEdited = false
                            })
        if (tab.routingDirty) {
            service.saveRouting({
                                    "enabled": tab.routingEnabled,
                                    "folders": tab.routingFolders,
                                    "extensions": tab.routingExtensions
                                }, changed ? undefined : "Sorting saved", error => {
                                    if (error)
                                        tab.saveError = tab.plainSaveError(error)
                                    else
                                        tab.routingEdited = false
                                })
        } else if (!changed && !tab.vpnDirty) {
            recount()
            service.notice("Nothing changed")
            return
        }
        if (!changed) {
            recount()
            return
        }
        service.saveOptions(options, "Applied " + changed + " change" + (changed === 1 ? "" : "s"), error => {
                                if (error) {
                                    tab.saveError = tab.plainSaveError(error)
                                    return
                                }
                                tab.edits = ({})
                                tab.recount()
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
        seedVpn()
        if (service.requestedLog)
            revealLog()
    }

    //: Where downloads go by file type. Held here while it is edited, saved
    //: with everything else by the page's Save button.
    property bool routingEnabled: false
    property var routingFolders: ({})
    property var routingExtensions: ({})
    //: Touched since it was seeded; dirty only while it differs from what
    //: the manager has, so putting a change back clears the save bar.
    property bool routingEdited: false
    readonly property bool routingDirty: {
        const saved = service ? service.routing : null
        if (!routingEdited || !saved)
            return false
        return routingEnabled !== (saved.enabled === true) || !Units.sameMap(routingFolders, saved.folders)
               || !Units.sameMap(routingExtensions, saved.extensions)
    }
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
        routingEdited = false
    }

    function setRoutingFolder(category, value) {
        const next = Object.assign({}, routingFolders)
        next[category] = value
        routingFolders = next
        routingEdited = true
    }

    function setRoutingExtensions(category, text) {
        const next = Object.assign({}, routingExtensions)
        next[category] = text.split(/[\s,]+/).filter(part => part.length > 0)
        routingExtensions = next
        routingEdited = true
    }

    Connections {
        target: tab.service
        function onRoutingChanged() {
            tab.seedRouting()
        }
        //: Saved values reloaded (after a save, or changed elsewhere): an edit
        //: may now match them.
        function onGlobalOptionsChanged() {
            tab.recount()
        }
    }

    //: The download-only VPN (the manager's vpn.py), held here while it is
    //: edited and saved with everything else; its status line is live.
    readonly property string home: Quickshell.env("HOME") || ""
    property bool vpnEnabled: false
    property string vpnFolder: ""
    property string vpnServer: ""
    property var vpnSites: []
    //: Touched since it was seeded; dirty only while it differs from what
    //: the manager has, so putting a change back clears the save bar.
    property bool vpnEdited: false
    readonly property bool vpnDirty: vpnEdited && (vpnEnabled !== (vpnLive.enabled === true) || vpnFolder !== (vpnLive.folder || "")
                                                   || vpnServer !== (vpnLive.server || "")
                                                   || JSON.stringify(vpnSites) !== JSON.stringify(vpnLive.sites || []))
    property bool vpnAdding: false
    readonly property var vpnLive: service ? service.vpn : ({})

    function seedVpn() {
        const v = vpnLive || ({})
        vpnEnabled = v.enabled === true
        vpnFolder = v.folder || ""
        vpnServer = v.server || ""
        vpnSites = (v.sites || []).slice()
        vpnEdited = false
    }

    //: The live state arrives with every frame; it only resets an unedited card.
    onVpnLiveChanged: if (!vpnEdited)
                          seedVpn()

    //: What the tunnel is doing, in words, and the dot's colour.
    readonly property var vpnStatus: {
        const v = vpnLive || ({})
        const name = String(v.server || "").replace(/\.conf$/i, "")
        if (vpnDirty)
            return ["Unsaved changes. Save to apply them.", Theme.outline]
        if (!v.enabled)
            return ["Off. All downloads use your normal connection.", Theme.outline]
        if (!v.installed)
            return ["wireproxy isn’t installed. Install it with: sudo pacman -S wireproxy", Theme.error]
        if (!(v.servers || []).length)
            return ["No WireGuard configs found in " + Fmt.homePath(v.folder, tab.home) + ". Add your Proton .conf files there.", Theme.error]
        if (v.connected)
            return ["Connected via " + name, Theme.success]
        if (v.running)
            return ["Connecting via " + name + "…", Theme.warning]
        return ["Not running" + (v.lastError ? ": " + v.lastError : ""), Theme.error]
    }

    function addVpnSites(text) {
        const added = text.split(/[\s,]+/).map(s => Vpn.vpnSiteOf(s)).filter(s => s.length > 0 && tab.vpnSites.indexOf(s) < 0)
        if (!added.length)
            return
        vpnSites = vpnSites.concat(added)
        vpnEdited = true
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
            font.weight: Font.DemiBold
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

            // ---- find a setting (both modes), or jump to a group --------------
            Column {
                width: parent.width
                spacing: 10

                SearchPill {
                    id: searchField

                    width: parent.width
                    placeholderText: "Search settings"
                    trailingText: tab.searchHits + " found"
                    onTextChanged: tab.search = text.trim()
                }

                Item {
                    width: parent.width
                    height: 32
                    visible: tab.advancedOnlyHits > 0

                    StyledText {
                        anchors.left: parent.left
                        anchors.leftMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        text: tab.advancedOnlyHits === 1 ? "1 more match in Advanced" : tab.advancedOnlyHits + " more matches in Advanced"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    PillButton {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        size: 30
                        kind: "text"
                        text: "Show"
                        onClicked: tab.setMode("advanced")
                    }
                }

                //: The window's section list already jumps; the chips are for
                //: the popout.
                Flow {
                    width: parent.width
                    visible: tab.advanced && !tab.search && !tab.wide
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
                visible: tab.folderCardFound || (!tab.advanced && tab.hits(tab.simpleOptions) > 0)

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
                                tab.routingEdited = true
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
                        visible: tab.matches(simpleOption.modelData[0], simpleOption.modelData[1])
                        divider: true
                        highlight: tab.search
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
                visible: tab.routingEnabled && tab.routingCardFound
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

            // ---- the VPN for downloads ---------------------------------------
            Card {
                id: vpnCard

                width: content.width
                visible: tab.vpnCardFound
                padding: 14

                Column {
                    width: parent.width
                    spacing: 10
                    bottomPadding: 4

                    Item {
                        width: parent.width
                        height: 32

                        StyledText {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: "VPN for downloads"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.DemiBold
                            color: Theme.surfaceText
                        }

                        BoolSwitch {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            checked: tab.vpnEnabled
                            onToggled: value => {
                                tab.vpnEnabled = value
                                tab.vpnEdited = true
                            }
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: 8

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 8
                            height: 8
                            radius: 4
                            color: tab.vpnStatus[1]
                        }

                        StyledText {
                            width: parent.width - 16
                            anchors.verticalCenter: parent.verticalCenter
                            text: tab.vpnStatus[0]
                            wrapMode: Text.WordWrap
                            font.pixelSize: Theme.fontSizeSmall
                            color: tab.vpnStatus[1] === Theme.error ? Theme.error : Theme.surfaceVariantText
                        }
                    }

                    Column {
                        width: parent.width
                        spacing: 10
                        opacity: tab.vpnEnabled ? 1 : 0.55

                        //: The server: one of the folder's .conf files.
                        Item {
                            width: parent.width
                            height: 36

                            StyledText {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Server"
                                font.pixelSize: Theme.fontSizeSmall + 1
                                color: Theme.surfaceText
                            }

                            PillButton {
                                id: serverButton

                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                size: 34
                                kind: "outlined"
                                icon: "dns"
                                enabled: (tab.vpnLive.servers || []).length > 0
                                text: tab.vpnServer ? tab.vpnServer.replace(/\.conf$/i, "") : "No configs found"
                                onClicked: serverMenu.toggle()

                                MenuPopup {
                                    id: serverMenu

                                    alignEnd: true
                                    menuWidth: 260
                                    entries: (tab.vpnLive.servers || []).map(s => ({
                                                                                      "icon": "dns",
                                                                                      "text": s.replace(/\.conf$/i, ""),
                                                                                      "checked": s === tab.vpnServer
                                                                                  }))
                                    onTriggered: index => {
                                        tab.vpnServer = tab.vpnLive.servers[index]
                                        tab.vpnEdited = true
                                    }
                                }
                            }
                        }

                        //: The folder of configs; a new one lists its files once saved.
                        Column {
                            width: parent.width
                            spacing: 4

                            StyledText {
                                text: "Config folder · one .conf file per server"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }

                            DirectoryField {
                                width: parent.width
                                placeholderText: "~/.config/aria-download-manager/wireguard"
                                dialogTitle: "Choose the WireGuard config folder"
                                startDir: tab.vpnFolder
                                text: tab.vpnFolder
                                onTextChanged: if (text !== tab.vpnFolder) {
                                                   tab.vpnFolder = text
                                                   tab.vpnEdited = true
                                               }
                            }
                        }

                        //: The sites whose downloads use it, as chips: a tap takes
                        //: one off, "+ add site" puts one on (a pasted link
                        //: becomes its site).
                        Column {
                            width: parent.width
                            spacing: 6

                            StyledText {
                                text: "Sites that use the VPN (subdomains included)"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }

                            Flow {
                                width: parent.width
                                spacing: 6

                                Repeater {
                                    model: tab.vpnSites

                                    Rectangle {
                                        id: siteChip

                                        required property string modelData

                                        width: siteRow.implicitWidth + 18
                                        height: 26
                                        radius: 13
                                        color: Theme.surfaceContainerHighest

                                        Row {
                                            id: siteRow

                                            anchors.centerIn: parent
                                            spacing: 4

                                            StyledText {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: siteChip.modelData
                                                font.pixelSize: Theme.fontSizeSmall - 1
                                                font.family: "monospace"
                                                color: Theme.surfaceText
                                            }

                                            DankIcon {
                                                anchors.verticalCenter: parent.verticalCenter
                                                name: "close"
                                                size: 12
                                                color: siteArea.containsMouse ? Theme.surfaceText : Theme.surfaceVariantText
                                            }
                                        }

                                        MouseArea {
                                            id: siteArea

                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                tab.vpnSites = tab.vpnSites.filter(s => s !== siteChip.modelData)
                                                tab.vpnEdited = true
                                            }
                                        }
                                    }
                                }

                                Rectangle {
                                    width: tab.vpnAdding ? 170 : addSiteLabel.implicitWidth + 20
                                    height: 26
                                    radius: 13
                                    color: "transparent"
                                    border.width: 1
                                    border.color: tab.vpnAdding ? Theme.primary : Theme.outlineVariant

                                    StyledText {
                                        id: addSiteLabel

                                        anchors.centerIn: parent
                                        visible: !tab.vpnAdding
                                        text: "+ add site"
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.surfaceText
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        visible: !tab.vpnAdding
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            tab.vpnAdding = true
                                            siteInput.forceActiveFocus()
                                        }
                                    }

                                    TextInput {
                                        id: siteInput

                                        anchors.fill: parent
                                        anchors.leftMargin: 10
                                        anchors.rightMargin: 10
                                        verticalAlignment: TextInput.AlignVCenter
                                        visible: tab.vpnAdding
                                        color: Theme.surfaceText
                                        clip: true
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        font.family: "monospace"
                                        onAccepted: {
                                            tab.addVpnSites(text)
                                            text = ""
                                        }
                                        onActiveFocusChanged: if (!activeFocus) {
                                                                  tab.addVpnSites(text)
                                                                  text = ""
                                                                  tab.vpnAdding = false
                                                              }
                                        Keys.onEscapePressed: {
                                            text = ""
                                            focus = false
                                        }
                                    }
                                }
                            }
                        }
                    }

                    StyledText {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: "Only downloads set to use the VPN go through it; torrents and the rest of your system are unaffected. If the tunnel goes down, those downloads stop instead of falling back to your normal connection."
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
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
                visible: tab.advanced && (!tab.searching || found > 0)

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
                        font.weight: Font.DemiBold
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
                visible: tab.advanced && (!tab.searching || tab.procCardFound)

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
                visible: tab.advanced && (!tab.searching || tab.logCardFound)

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
                        font.weight: tab.logExpanded ? Font.DemiBold : Font.Medium
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
            text: tab.changeTotal === 1 ? "1 unsaved change" : tab.changeTotal + " unsaved changes"
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
