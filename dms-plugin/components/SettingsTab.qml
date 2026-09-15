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

    function setMode(mode) {
        PluginService.savePluginData("ariaDownloadManager", "settingsMode", mode)
    }

    //: The log lives at the bottom of the Advanced page.
    //: `dms ipc call ariaDownloadManager tab log` opens this tab with the
    //: section unfolded and scrolls down to it.
    property bool logExpanded: false

    readonly property int scrollbarGutter: Layout.SCROLLBAR_GUTTER

    //: Simple: the same seven the manager page shows, so both surfaces teach
    //: the same starting point.
    readonly property var simpleOptions: [
        ["dir", "Download folder", "text", "Where finished files go."],
        ["max-concurrent-downloads", "Downloads at once", "number", "How many run in parallel; the rest wait in the queue."],
        ["max-connection-per-server", "Connections per server", "number", "Up to 16. More connections usually means faster downloads from one server."],
        ["split", "Parts per download", "number", "A file is fetched in this many pieces at the same time."],
        ["max-overall-download-limit", "Download speed limit", "text", "Across every download. Blank means no limit."],
        ["max-overall-upload-limit", "Upload speed limit", "text", "For torrents. Blank means no limit."],
        ["continue", "Resume unfinished files", "bool", "Pick up a partial file where it stopped instead of starting over."]
    ]

    // Same grouping the manager page uses, so both front-ends teach the same
    // map of aria2's option surface.
    readonly property var groups: [
        {
            "title": "Queue and parallelism",
            "options": [["max-concurrent-downloads", "Downloads at once", "number"], ["max-connection-per-server", "Connections per server (up to 16)", "number"], ["split", "Parts per download", "number"], ["min-split-size", "Smallest part", "text"], ["optimize-concurrent-downloads", "Tune parallelism automatically", "bool"]]
        },
        {
            "title": "Speed limits",
            "options": [["max-overall-download-limit", "Download limit, all downloads", "text"], ["max-download-limit", "Download limit, each download", "text"], ["max-overall-upload-limit", "Upload limit, all downloads", "text"], ["max-upload-limit", "Upload limit, each download", "text"], ["lowest-speed-limit", "Give up below this speed", "text"]]
        },
        {
            "title": "Retries and timeouts",
            "options": [["max-tries", "Attempts (0 = unlimited)", "number"], ["retry-wait", "Wait between attempts (s)", "number"], ["timeout", "Timeout (s)", "number"], ["connect-timeout", "Connect timeout (s)", "number"], ["max-file-not-found", "Not-found replies before giving up", "number"]]
        },
        {
            "title": "Disk and files",
            "options": [["dir", "Download folder", "text"], ["file-allocation", "File allocation", "select:none,prealloc,trunc,falloc"], ["disk-cache", "Disk cache", "text"], ["continue", "Resume unfinished files", "bool"], ["allow-overwrite", "Overwrite existing files", "bool"], ["auto-file-renaming", "Rename duplicates automatically", "bool"], ["remote-time", "Keep the server's timestamps", "bool"]]
        },
        {
            "title": "HTTP",
            "options": [["user-agent", "User agent", "text"], ["referer", "Referer", "text"], ["http-accept-gzip", "Accept gzip", "bool"], ["all-proxy", "Proxy for every protocol", "text"], ["check-certificate", "Verify TLS certificates", "bool"]]
        },
        {
            "title": "BitTorrent",
            "options": [["follow-torrent", "Start downloaded torrents automatically", "bool"], ["bt-max-peers", "Peers per torrent", "number"], ["seed-ratio", "Seed until this ratio", "text"], ["seed-time", "Seed for this long (min)", "text"], ["enable-dht", "Use DHT", "bool"], ["bt-max-open-files", "Open files at once", "number"]]
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
        const keys = Object.keys(opts).filter(k => coveredKeys.indexOf(k) === -1)
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

    function matches(key, label) {
        if (!search)
            return true
        const needle = search.toLowerCase()
        return key.toLowerCase().indexOf(needle) >= 0 || label.toLowerCase().indexOf(needle) >= 0
    }

    function record(key, value) {
        edits[key] = value
    }

    function save() {
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
        if (!changed) {
            service.notice("Nothing changed")
            return
        }
        service.saveOptions(options, "Applied " + changed + " change" + (changed === 1 ? "" : "s"))
        edits = ({})
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

    Timer {
        id: scrollToLog

        //: The flickable's contentHeight only grows once the unfolded log has
        //: been laid out, and scrolling before that lands short of the bottom.
        interval: 60
        repeat: false
        onTriggered: flick.contentY = Math.max(0, flick.contentHeight - flick.height)
    }

    Component.onCompleted: {
        if (!service)
            return
        service.loadOptions()
        if (service.requestedLog)
            revealLog()
    }

    Connections {
        target: tab.service
        function onRequestedLogChanged() {
            if (tab.service.requestedLog)
                tab.revealLog()
        }
    }

    // ---- header: mode, search, save --------------------------------------
    Item {
        id: header

        width: parent.width
        height: 44

        DankButtonGroup {
            id: modeGroup

            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            size: "small"
            model: ["Simple", "Advanced"]
            currentIndex: tab.advanced ? 1 : 0
            onSelectionChanged: (index, selected) => {
                if (selected)
                    tab.setMode(index === 1 ? "advanced" : "simple")
            }
        }

        DankTextField {
            id: searchField

            anchors.left: modeGroup.right
            anchors.leftMargin: Theme.spacingS
            anchors.right: saveButton.left
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            height: 40
            visible: tab.advanced
            leftIconName: "search"
            placeholderText: "Find an option"
            showClearButton: true
            onTextChanged: tab.search = text
        }

        DankButton {
            id: saveButton

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Save changes"
            iconName: "save"
            buttonHeight: 40
            backgroundColor: Theme.primary
            textColor: Theme.onPrimary
            onClicked: tab.save()
        }
    }

    DankFlickable {
        id: flick

        anchors.top: header.bottom
        anchors.topMargin: Theme.spacingS
        anchors.bottom: parent.bottom
        width: parent.width
        clip: true
        contentHeight: content.implicitHeight
        contentWidth: width

        Column {
            id: content

            // The scrollbar is drawn over the flickable's right edge, so the
            // content stops short of it.
            width: parent.width - tab.scrollbarGutter
            spacing: Theme.spacingM

            StyledText {
                width: parent.width
                text: {
                    const cfg = tab.service ? tab.service.serverConfig : null
                    const where = cfg && cfg.config_path ? " and saved to " + cfg.config_path : ""
                    return "Changes apply to the running aria2c right away" + where + "."
                }
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            // ---- simple ------------------------------------------------
            Rectangle {
                width: parent.width
                visible: !tab.advanced
                height: visible ? simpleColumn.implicitHeight + Theme.spacingM * 2 : 0
                radius: Theme.cornerRadius
                color: Theme.surfaceContainer

                Column {
                    id: simpleColumn

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.spacingM
                    spacing: Theme.spacingS

                    Repeater {
                        model: tab.advanced ? [] : tab.simpleOptions

                        OptionField {
                            id: simpleOption

                            required property var modelData

                            width: simpleColumn.width
                            optionKey: simpleOption.modelData[0]
                            label: simpleOption.modelData[1]
                            kind: simpleOption.modelData[2]
                            description: simpleOption.modelData[3]
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
            }

            // ---- advanced: curated groups -------------------------------
            Repeater {
                model: tab.advanced ? tab.groups : []

                Rectangle {
                    id: group

                    required property var modelData

                    width: content.width
                    height: visible ? groupColumn.implicitHeight + Theme.spacingM * 2 : 0
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainer
                    visible: {
                        if (!tab.search)
                            return true
                        const opts = group.modelData.options
                        for (var i = 0; i < opts.length; i++) {
                            if (tab.matches(opts[i][0], opts[i][1]))
                                return true
                        }
                        return false
                    }

                    Column {
                        id: groupColumn

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingXS

                        StyledText {
                            text: group.modelData.title.toUpperCase()
                            font.pixelSize: Theme.fontSizeSmall - 1
                            font.weight: Font.Bold
                            font.letterSpacing: 0.8
                            color: Theme.surfaceVariantText
                            bottomPadding: Theme.spacingXS
                        }

                        Grid {
                            id: groupGrid

                            width: parent.width
                            columns: 2
                            columnSpacing: Theme.spacingM
                            rowSpacing: Theme.spacingXS

                            Repeater {
                                model: group.modelData.options

                                OptionField {
                                    id: option

                                    required property var modelData

                                    width: (groupGrid.width - Theme.spacingM) / 2
                                    optionKey: option.modelData[0]
                                    label: option.modelData[1]
                                    kind: option.modelData[2]
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
                }
            }

            // ---- advanced: every option aria2 reports -------------------
            DankCollapsibleSection {
                width: content.width
                visible: tab.advanced
                title: "Every aria2 option · " + tab.advancedKeys.length
                expanded: false
                showBackground: true

                Repeater {
                    model: tab.advanced ? tab.advancedGroups : []

                    Column {
                        id: advGroup

                        required property var modelData

                        width: content.width - Theme.spacingM * 2
                        spacing: Theme.spacingXS
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
                            text: advGroup.modelData.title.toUpperCase()
                            font.pixelSize: Theme.fontSizeSmall - 1
                            font.weight: Font.Bold
                            font.letterSpacing: 0.8
                            color: Theme.surfaceVariantText
                            topPadding: Theme.spacingS
                        }

                        Grid {
                            width: parent.width
                            columns: 2
                            columnSpacing: Theme.spacingM
                            rowSpacing: Theme.spacingXS

                            Repeater {
                                model: advGroup.modelData.keys

                                OptionField {
                                    id: advancedOption

                                    required property var modelData

                                    width: (parent.width - Theme.spacingM) / 2
                                    optionKey: advancedOption.modelData
                                    label: advancedOption.modelData
                                    kind: (original === "true" || original === "false") ? "bool" : "text"
                                    description: OptionHelp.forKey(advancedOption.modelData)
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
            }

            // ---- advanced: the two processes ----------------------------
            Rectangle {
                width: parent.width
                visible: tab.advanced
                height: visible ? procColumn.implicitHeight + Theme.spacingM * 2 : 0
                radius: Theme.cornerRadius
                color: Theme.surfaceContainer

                Column {
                    id: procColumn

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.spacingM
                    spacing: Theme.spacingXS

                    Item {
                        width: parent.width
                        height: 40

                        StyledText {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: "aria2c process"
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }

                        Row {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS

                            DankButton {
                                text: "Restart manager"
                                iconName: "restart_alt"
                                buttonHeight: 34
                                backgroundColor: Theme.surfaceContainerHigh
                                textColor: Theme.surfaceText
                                onClicked: tab.service.restartManager()
                            }

                            DankButton {
                                text: "Restart aria2c"
                                iconName: "restart_alt"
                                buttonHeight: 34
                                backgroundColor: Theme.errorHover
                                textColor: Theme.error
                                onClicked: tab.service.post("/api/aria2/restart", null, "aria2c restarted")
                            }
                        }
                    }

                    Repeater {
                        model: {
                            const aria2 = tab.service ? tab.service.aria2 : ({})
                            return [["Managed", aria2.managed ? "Yes, started by the manager" : "No, external process"], ["Running", aria2.running ? "Yes" : "No"], ["PID", String(aria2.pid !== undefined && aria2.pid !== null ? aria2.pid : "—")], ["Version", aria2.version || "—"], ["RPC address", aria2.rpc_url || "—"], ["Uptime", Fmt.eta(aria2.uptime)], ["Restarts", String(aria2.restarts || 0)], ["Log file", aria2.log_file || "—"], ["Session file", aria2.session_file || "—"], ["Last error", aria2.last_error || "None"]]
                        }

                        Row {
                            id: procRow

                            required property var modelData

                            width: procColumn.width
                            height: 20
                            spacing: Theme.spacingS

                            StyledText {
                                width: 100
                                text: procRow.modelData[0]
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }

                            StyledText {
                                width: Math.max(0, parent.width - 100 - Theme.spacingS)
                                text: procRow.modelData[1]
                                font.pixelSize: Theme.fontSizeSmall
                                color: procRow.modelData[0] === "Last error" && procRow.modelData[1] !== "None" ? Theme.error : Theme.surfaceText
                                elide: Text.ElideMiddle
                            }
                        }
                    }
                }
            }

            // ---- advanced: event log ------------------------------------
            // Diagnostic material rather than a main view, so it holds no tab
            // of its own: it sits folded at the bottom, under the process card
            // it usually explains.
            Rectangle {
                width: parent.width
                visible: tab.advanced
                height: visible ? logColumn.implicitHeight + Theme.spacingM * 2 : 0
                radius: Theme.cornerRadius
                color: Theme.surfaceContainer

                Column {
                    id: logColumn

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.spacingM
                    spacing: Theme.spacingS

                    Item {
                        width: parent.width
                        height: 32

                        StyledText {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Event log · " + (tab.service ? tab.service.events.length : 0)
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }

                        DankIcon {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            name: "expand_more"
                            rotation: tab.logExpanded ? 180 : 0
                            size: Theme.iconSize - 4
                            color: Theme.surfaceVariantText

                            Behavior on rotation {
                                NumberAnimation {
                                    duration: Theme.shortDuration
                                    easing.type: Theme.standardEasing
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: tab.logExpanded = !tab.logExpanded
                        }
                    }

                    LogTab {
                        // Inset again: this list carries its own scrollbar.
                        width: parent.width - tab.scrollbarGutter
                        visible: tab.logExpanded
                        height: visible ? 320 : 0
                        service: tab.service
                        compact: true
                    }
                }
            }
        }
    }
}
