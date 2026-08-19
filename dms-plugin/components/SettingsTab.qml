import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt

Item {
    id: tab

    property var service: null
    property var edits: ({})
    property string search: ""
    property bool showAdvanced: false

    // Same grouping the web UI uses, so both front-ends teach the same map of
    // aria2's option surface.
    readonly property var groups: [
        {
            "title": "Queue & parallelism",
            "options": [["max-concurrent-downloads", "Max concurrent downloads", "number"], ["max-connection-per-server", "Connections per server (max 16)", "number"], ["split", "Split — parts per download", "number"], ["min-split-size", "Minimum part size", "text"], ["optimize-concurrent-downloads", "Auto-tune concurrency", "bool"]]
        },
        {
            "title": "Speed limits",
            "options": [["max-overall-download-limit", "Overall download limit", "text"], ["max-download-limit", "Per-download limit", "text"], ["max-overall-upload-limit", "Overall upload limit", "text"], ["max-upload-limit", "Per-download upload limit", "text"], ["lowest-speed-limit", "Abort below this speed", "text"]]
        },
        {
            "title": "Retries & timeouts",
            "options": [["max-tries", "Max tries (0 = unlimited)", "number"], ["retry-wait", "Retry wait (s)", "number"], ["timeout", "Timeout (s)", "number"], ["connect-timeout", "Connect timeout (s)", "number"], ["max-file-not-found", "Max 404s before giving up", "number"]]
        },
        {
            "title": "Disk & files",
            "options": [["dir", "Download directory", "text"], ["file-allocation", "File allocation", "select:none,prealloc,trunc,falloc"], ["disk-cache", "Disk cache", "text"], ["continue", "Resume partial files", "bool"], ["allow-overwrite", "Allow overwrite", "bool"], ["auto-file-renaming", "Auto-rename duplicates", "bool"], ["remote-time", "Use server timestamps", "bool"]]
        },
        {
            "title": "HTTP",
            "options": [["user-agent", "User-Agent", "text"], ["referer", "Referer", "text"], ["http-accept-gzip", "Accept gzip", "bool"], ["all-proxy", "Proxy (all protocols)", "text"], ["check-certificate", "Verify TLS certificates", "bool"]]
        },
        {
            "title": "BitTorrent",
            "options": [["follow-torrent", "Auto-start downloaded torrents", "bool"], ["bt-max-peers", "Max peers", "number"], ["seed-ratio", "Seed ratio", "text"], ["seed-time", "Seed time (min)", "text"], ["enable-dht", "Enable DHT", "bool"], ["bt-max-open-files", "Max open files", "number"]]
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
            if (String(edits[key]) !== original) {
                options[key] = String(edits[key])
                changed++
            }
        }
        if (!changed) {
            ToastService.showInfo("aria2c", "Nothing changed")
            return
        }
        service.saveOptions(options, "Applied " + changed + " option(s)")
        edits = ({})
    }

    Component.onCompleted: {
        if (service)
            service.loadOptions()
    }

    Row {
        id: header

        width: parent.width
        height: 44
        spacing: Theme.spacingS

        DankTextField {
            width: Math.max(0, parent.width - reloadButton.width - saveButton.width - Theme.spacingS * 2)
            height: 40
            leftIconName: "search"
            placeholderText: "Filter options…"
            showClearButton: true
            onTextChanged: tab.search = text
        }

        DankButton {
            id: reloadButton

            width: 120
            text: "Reload"
            iconName: "refresh"
            buttonHeight: 40
            backgroundColor: Theme.surfaceContainerHigh
            textColor: Theme.surfaceText
            onClicked: {
                tab.edits = ({})
                tab.service.loadOptions()
            }
        }

        DankButton {
            id: saveButton

            width: 100
            text: "Save"
            iconName: "save"
            buttonHeight: 40
            backgroundColor: Theme.primary
            textColor: Theme.onPrimary
            onClicked: tab.save()
        }
    }

    DankFlickable {
        anchors.top: header.bottom
        anchors.topMargin: Theme.spacingS
        anchors.bottom: parent.bottom
        width: parent.width
        clip: true
        contentHeight: content.implicitHeight
        contentWidth: width

        Column {
            id: content

            width: parent.width
            spacing: Theme.spacingM

            StyledText {
                width: parent.width
                text: "Manager"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Bold
                color: Theme.surfaceText
            }

            Rectangle {
                width: parent.width
                height: webUiRow.implicitHeight + Theme.spacingM * 2
                radius: Theme.cornerRadius
                color: Theme.surfaceContainer
                border.width: 1
                border.color: Theme.withAlpha(Theme.outline, 0.12)

                Item {
                    id: webUiRow

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.spacingM
                    implicitHeight: Math.max(webUiText.implicitHeight, webUiToggle.height)

                    Column {
                        id: webUiText

                        anchors.left: parent.left
                        anchors.right: webUiToggle.left
                        anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        StyledText {
                            width: parent.width
                            text: "Web UI"
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceText
                        }

                        StyledText {
                            width: parent.width
                            text: {
                                if (!tab.service)
                                    return ""
                                const base = "Serve the browser UI at " + tab.service.baseUrl + "/. "
                                return base + (tab.service.restartRequired
                                    ? "Restart the manager to apply."
                                    : "Off by default — this widget talks to the API directly.")
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            color: tab.service && tab.service.restartRequired ? Theme.warning : Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }
                    }

                    DankToggle {
                        id: webUiToggle

                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        checked: tab.service ? tab.service.webUiEnabled : false
                        hideText: true
                        onToggled: checked => tab.service.setManagerConfig({
                                                                               "web_ui": checked
                                                                           }, checked ? "Web UI on after a restart" : "Web UI off after a restart")
                    }
                }
            }

            DankButton {
                text: "Restart manager"
                iconName: "restart_alt"
                buttonHeight: 40
                backgroundColor: tab.service && tab.service.restartRequired ? Theme.primary : Theme.surfaceContainerHigh
                textColor: tab.service && tab.service.restartRequired ? Theme.onPrimary : Theme.surfaceText
                onClicked: tab.service.restartManager()
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Theme.withAlpha(Theme.outline, 0.15)
            }

            StyledText {
                width: parent.width
                text: "aria2 options"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Bold
                color: Theme.surfaceText
            }

            StyledText {
                width: parent.width
                text: tab.service && tab.service.serverConfig
                      ? "Applied to the running aria2c immediately and written to " + tab.service.serverConfig.config_path
                      : "Changes apply to the running aria2c immediately."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            Repeater {
                model: tab.groups

                Column {
                    id: group

                    required property var modelData

                    width: content.width
                    spacing: Theme.spacingXS
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

                    StyledText {
                        text: group.modelData.title
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Bold
                        color: Theme.surfaceText
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

            Rectangle {
                width: parent.width
                height: 1
                color: Theme.withAlpha(Theme.outline, 0.15)
            }

            Row {
                spacing: Theme.spacingXS

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: tab.showAdvanced ? "expand_less" : "expand_more"
                    size: Theme.iconSizeSmall
                    color: Theme.surfaceText
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "All options (advanced) — " + tab.advancedKeys.length
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: tab.showAdvanced = !tab.showAdvanced
                }
            }

            Grid {
                width: parent.width
                visible: tab.showAdvanced
                columns: 2
                columnSpacing: Theme.spacingM
                rowSpacing: Theme.spacingXS

                Repeater {
                    model: tab.showAdvanced ? tab.advancedKeys : []

                    OptionField {
                        id: advancedOption

                        required property var modelData

                        width: (parent.width - Theme.spacingM) / 2
                        optionKey: advancedOption.modelData
                        label: advancedOption.modelData
                        kind: "text"
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

            Rectangle {
                width: parent.width
                height: 1
                color: Theme.withAlpha(Theme.outline, 0.15)
            }

            StyledText {
                text: "aria2c process"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Bold
                color: Theme.surfaceText
            }

            Repeater {
                model: {
                    const aria2 = tab.service ? tab.service.aria2 : ({})
                    return [["Managed", aria2.managed ? "yes (spawned by manager)" : "no (external)"], ["Running", aria2.running ? "yes" : "no"], ["PID", String(aria2.pid !== undefined && aria2.pid !== null ? aria2.pid : "—")], ["Version", aria2.version || "—"], ["RPC URL", aria2.rpc_url || "—"], ["Uptime", Fmt.eta(aria2.uptime)], ["Restarts", String(aria2.restarts || 0)], ["Log file", aria2.log_file || "—"], ["Session file", aria2.session_file || "—"], ["Last error", aria2.last_error || "none"]]
                }

                Row {
                    id: procRow

                    required property var modelData

                    width: content.width
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
                        color: procRow.modelData[0] === "Last error" && procRow.modelData[1] !== "none" ? Theme.error : Theme.surfaceText
                        elide: Text.ElideMiddle
                    }
                }
            }

            DankButton {
                text: "Restart aria2c"
                iconName: "restart_alt"
                buttonHeight: 40
                backgroundColor: Theme.errorHover
                textColor: Theme.error
                onClicked: tab.service.post("/api/aria2/restart", null, "aria2c restarted")
            }
        }
    }
}
