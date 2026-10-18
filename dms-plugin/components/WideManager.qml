import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt
import "../lib/Rules.js" as Rules

//: The manager in a window wide enough to use its width: the filters and the
//: sections become a rail, the selected download opens in a pane beside the
//: list instead of pushing rows down, and the live totals sit in a status
//: bar. The window falls back to the popout's layout when it is narrow.
Item {
    id: manager

    property var service: null
    //: Whether the window is on screen; pings the service like the popout.
    property bool hostVisible: true

    //: "downloads", "actions" or "settings".
    property string section: service && service.requestedTab === 1 ? "actions" : (service && service.requestedTab === 2 ? "settings" : "downloads")
    property string filter: "all"
    property string selectedGid: ""

    readonly property bool online: !!service && service.connected
    readonly property var counts: service ? service.counts : ({})
    readonly property var selected: {
        if (!service || !selectedGid)
            return null
        return service.downloads.find(d => d.gid === selectedGid) || null
    }

    readonly property int railWidth: 210
    readonly property int paneWidth: 360
    readonly property int statusHeight: 34

    Connections {
        target: manager.service
        function onRequestedTabChanged() {
            manager.section = ["downloads", "actions", "settings"][manager.service.requestedTab] || "downloads"
        }
    }

    // While on screen it keeps the event stream alive, like the popout.
    Timer {
        interval: 1000
        repeat: true
        running: manager.hostVisible
        triggeredOnStart: true
        onTriggered: {
            if (manager.service)
                manager.service.viewerPing()
        }
    }

    function pick(section, filter) {
        manager.section = section
        if (section === "downloads" && filter !== undefined) {
            manager.filter = filter
            if (centre.item && centre.item.setFilter)
                centre.item.setFilter(filter)
        }
    }

    // ---- rail ----------------------------------------------------------------
    Column {
        id: rail

        anchors.left: parent.left
        anchors.top: parent.top
        width: manager.railWidth
        spacing: 2
        enabled: manager.online
        opacity: enabled ? 1 : 0.5

        PillButton {
            width: parent.width
            size: 44
            kind: "filled"
            icon: "add"
            text: "Add download"
            onClicked: {
                manager.pick("downloads")
                if (centre.item)
                    centre.item.adding = true
            }
        }

        Item {
            width: 1
            height: Theme.spacingS
        }

        Repeater {
            model: [
                ["inbox", "All", "all", (manager.counts.total || 0) + (manager.service ? manager.service.pastEntries.length : 0)],
                ["downloading", "Active", "active", manager.counts.active],
                ["schedule", "Queued", "waiting", manager.counts.waiting],
                ["pause_circle", "Paused", "paused", manager.counts.paused],
                ["task_alt", "Done", "complete", (manager.counts.complete || 0) + (manager.service ? manager.service.pastDone : 0)],
                ["error", "Failed", "error", (manager.counts.error || 0) + (manager.service ? manager.service.pastFailed : 0)]
            ]

            RailItem {
                required property var modelData

                icon: modelData[0]
                label: modelData[1]
                count: modelData[3] !== undefined ? String(modelData[3] || 0) : ""
                alarm: modelData[2] === "error" && (modelData[3] || 0) > 0
                selected: manager.section === "downloads" && manager.filter === modelData[2]
                onActivated: manager.pick("downloads", modelData[2])
            }
        }

        Item {
            width: 1
            height: 14
        }

        RailItem {
            icon: "auto_fix_high"
            label: "Actions"
            count: {
                if (!manager.service)
                    return ""
                if (!manager.service.rulesEnabled)
                    return "off"
                const on = manager.service.rules.filter(r => r.enabled !== false).length
                return on > 0 ? String(on) : ""
            }
            selected: manager.section === "actions"
            onActivated: manager.pick("actions")
        }

        RailItem {
            icon: "tune"
            label: "Settings"
            selected: manager.section === "settings"
            onActivated: manager.pick("settings")
        }
    }

    // ---- aria2c is down ------------------------------------------------------
    Rectangle {
        id: banner

        readonly property bool shown: manager.online && !manager.service.aria2Running

        anchors.left: rail.right
        anchors.leftMargin: Theme.spacingM
        anchors.right: parent.right
        anchors.top: parent.top
        height: shown ? 52 : 0
        visible: shown
        radius: 14
        color: Theme.withAlpha(Theme.error, 0.10)
        border.width: 1
        border.color: Theme.withAlpha(Theme.error, 0.35)

        DankIcon {
            id: bannerIcon

            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            name: "error"
            size: 20
            color: Theme.error
        }

        StyledText {
            anchors.left: bannerIcon.right
            anchors.leftMargin: Theme.spacingS
            anchors.right: bannerButton.left
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            text: "aria2c stopped — " + (manager.service && manager.service.aria2.last_error ? manager.service.aria2.last_error : "downloads resume where they were once it is back")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceText
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
        }

        PillButton {
            id: bannerButton

            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            size: 34
            kind: "filled"
            text: manager.service && manager.service.restarting === "aria2c" ? "Restarting…" : "Restart aria2c"
            busy: !!manager.service && manager.service.restarting === "aria2c"
            enabled: !!manager.service && manager.service.restarting === ""
            onClicked: manager.service.restartAria2()
        }
    }

    // ---- the list, or the Actions / Settings page ----------------------------
    Loader {
        id: centre

        anchors.left: rail.right
        anchors.leftMargin: Theme.spacingM
        anchors.right: manager.section === "downloads" ? pane.left : parent.right
        anchors.rightMargin: manager.section === "downloads" ? Theme.spacingM : 0
        anchors.top: banner.bottom
        anchors.topMargin: banner.shown ? Theme.spacingS : 0
        anchors.bottom: statusBar.top
        anchors.bottomMargin: Theme.spacingS
        visible: manager.online
        sourceComponent: manager.section === "actions" ? actionsPage : (manager.section === "settings" ? settingsPage : downloadsPage)

        onLoaded: {
            if (manager.section === "downloads" && item.setFilter)
                item.setFilter(manager.filter)
        }
    }

    Component {
        id: downloadsPage

        DownloadsTab {
            service: manager.service
            showChips: false
            pickMode: true
            selectedGid: manager.selectedGid
            onSelectedGidChanged: manager.selectedGid = selectedGid
            // The list changes its own filter too ("Show all downloads" on an
            // empty one); the rail follows, so both say the same.
            onFilterChanged: manager.filter = filter
        }
    }

    Component {
        id: actionsPage

        RulesTab {
            service: manager.service
            wide: true
        }
    }

    Component {
        id: settingsPage

        SettingsTab {
            service: manager.service
            wide: true
        }
    }

    // ---- the selected download ----------------------------------------------
    Rectangle {
        id: pane

        property bool confirmingRemove: false

        anchors.right: parent.right
        anchors.top: banner.bottom
        anchors.topMargin: banner.shown ? Theme.spacingS : 0
        anchors.bottom: statusBar.top
        anchors.bottomMargin: Theme.spacingS
        width: manager.paneWidth
        visible: manager.online && manager.section === "downloads"
        radius: 16
        color: Theme.surfaceContainer

        onVisibleChanged: confirmingRemove = false

        Connections {
            target: manager
            function onSelectedGidChanged() {
                pane.confirmingRemove = false
            }
        }

        StyledText {
            anchors.centerIn: parent
            width: parent.width - Theme.spacingXL * 2
            visible: !manager.selected
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "Pick a download to see its details here."
            font.pixelSize: Theme.fontSizeMedium
            color: Theme.surfaceVariantText
        }

        Column {
            id: paneHead

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingM
            visible: !!manager.selected
            spacing: Theme.spacingS

            readonly property var d: manager.selected || ({})
            readonly property bool live: d.status === "active" || d.status === "waiting" || d.status === "paused"

            Row {
                width: parent.width
                spacing: 12

                Rectangle {
                    width: 44
                    height: 44
                    radius: 12
                    color: Theme.surfaceContainerHighest

                    DankIcon {
                        anchors.centerIn: parent
                        name: Fmt.kindIcon(paneHead.d.name, paneHead.d.isTorrent, paneHead.d.isMetadata)
                        size: 20
                        color: Theme.surfaceText
                    }
                }

                Column {
                    width: parent.width - 44 - 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    StyledText {
                        width: parent.width
                        text: paneHead.d.name || paneHead.d.gid || ""
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                        wrapMode: Text.NoWrap
                        elide: Text.ElideMiddle
                    }

                    StyledText {
                        width: parent.width
                        text: Fmt.statusLabel(paneHead.d.status) + " · " + Math.floor(paneHead.d.progress || 0) + "%"
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                    }
                }
            }

            //: The few things done to a selected download, on top (board 9):
            //: the everyday one tonal, the folder outlined, removal round.
            Row {
                id: paneActions

                readonly property var main: {
                    const d = paneHead.d
                    if (d.status === "active")
                        return { "icon": "pause", "text": "Pause", "run": () => manager.service.setPaused(d.gid, true) }
                    if (d.status === "paused" || d.status === "waiting")
                        return { "icon": "play_arrow", "text": "Resume", "run": () => manager.service.setPaused(d.gid, false) }
                    if (d.status === "error")
                        return { "icon": "refresh", "text": "Retry", "run": () => manager.service.post("/api/download/" + d.gid + "/retry", null, "Added again") }
                    if (d.status === "complete" && !!d.path && d.fileExists !== false)
                        return { "icon": "open_in_new", "text": "Open", "run": () => Quickshell.execDetached(["xdg-open", d.path]) }
                    return null
                }
                readonly property bool hasFolder: !!(paneHead.d.dir || paneHead.d.path)
                readonly property int pills: (main ? 1 : 0) + (hasFolder ? 1 : 0)

                width: parent.width
                topPadding: 4
                spacing: 8

                PillButton {
                    visible: paneActions.main !== null
                    width: (paneActions.width - 36 - 8 * paneActions.pills) / Math.max(1, paneActions.pills)
                    size: 36
                    kind: "tonal"
                    icon: paneActions.main ? paneActions.main.icon : ""
                    text: paneActions.main ? paneActions.main.text : ""
                    onClicked: paneActions.main.run()
                }

                PillButton {
                    visible: paneActions.hasFolder
                    width: (paneActions.width - 36 - 8 * paneActions.pills) / Math.max(1, paneActions.pills)
                    size: 36
                    kind: "outlined"
                    icon: "folder_open"
                    text: "Folder"
                    onClicked: Quickshell.execDetached(["xdg-open", paneHead.d.dir || String(paneHead.d.path).replace(/\/[^/]*$/, "")])
                }

                //: Round and outlined, the × in the error colour.
                Rectangle {
                    width: 36
                    height: 36
                    radius: 18
                    color: removeArea.containsMouse ? Theme.withAlpha(Theme.error, 0.10) : "transparent"
                    border.width: 1
                    border.color: Theme.outlineVariant

                    DankIcon {
                        anchors.centerIn: parent
                        name: paneHead.live ? "close" : "delete"
                        size: 18
                        color: Theme.error
                    }

                    MouseArea {
                        id: removeArea

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (paneHead.live)
                                manager.service.removeDownload(paneHead.d.gid, true, "Cancelled and cleaned up")
                            else
                                pane.confirmingRemove = true
                        }
                    }
                }
            }

            //: A finished download's file is the point of it: keep or delete.
            Rectangle {
                width: parent.width
                visible: pane.confirmingRemove
                height: visible ? removeColumn.implicitHeight + 24 : 0
                radius: 12
                color: Theme.withAlpha(Theme.error, 0.06)
                border.width: 1
                border.color: Theme.withAlpha(Theme.error, 0.45)

                Column {
                    id: removeColumn

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 8

                    StyledText {
                        width: parent.width
                        text: paneHead.d.fileExists === false ? "The file is already gone." : "Remove from the list. Keep the file on disk?"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                    }

                    Row {
                        spacing: 4

                        PillButton {
                            size: 32
                            kind: "filled"
                            text: paneHead.d.fileExists === false ? "Remove entry" : "Keep file"
                            onClicked: {
                                pane.confirmingRemove = false
                                manager.service.removeDownload(paneHead.d.gid, false, "Removed")
                            }
                        }

                        PillButton {
                            visible: paneHead.d.fileExists !== false
                            size: 32
                            kind: "dangerTonal"
                            text: "Delete file"
                            onClicked: {
                                pane.confirmingRemove = false
                                manager.service.removeDownload(paneHead.d.gid, true, "Removed with its file")
                            }
                        }

                        PillButton {
                            size: 32
                            kind: "text"
                            text: "Cancel"
                            onClicked: pane.confirmingRemove = false
                        }
                    }
                }
            }
        }

        DankFlickable {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: paneHead.bottom
            anchors.topMargin: Theme.spacingS
            anchors.bottom: parent.bottom
            anchors.leftMargin: Theme.spacingM
            anchors.bottomMargin: Theme.spacingS
            visible: !!manager.selected
            clip: true
            contentHeight: paneDetail.item ? paneDetail.item.implicitHeight : 0
            contentWidth: width

            //: Rebuilt per download, so tabs and edits never carry over.
            Loader {
                id: paneDetail

                width: parent.width - Theme.spacingM
                active: !!manager.selected

                sourceComponent: DetailPanel {
                    width: paneDetail.width
                    tileColor: Theme.surfaceContainerHigh
                    service: manager.service
                    gid: manager.selectedGid
                    dl: manager.selected || ({})
                    held: manager.service.isHeldForChoice(manager.selected)
                }
            }
        }
    }

    // ---- the manager is not there -------------------------------------------
    //: The rail stays, so the window keeps its shape when the manager returns.
    Column {
        anchors.left: rail.right
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.spacingXL
        anchors.rightMargin: Theme.spacingXL
        visible: !manager.online
        spacing: Theme.spacingS

        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: manager.service && manager.service.restarting === "manager" ? "Restarting the manager…" : "The manager isn't running"
            font.pixelSize: Theme.fontSizeLarge
            font.weight: Font.Bold
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: manager.service ? manager.service.socketPath : ""
            font.pixelSize: Theme.fontSizeSmall
            font.family: "monospace"
            color: Theme.surfaceVariantText
            wrapMode: Text.NoWrap
            elide: Text.ElideMiddle
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingS
            visible: !(manager.service && manager.service.restarting === "manager")

            PillButton {
                kind: "filled"
                text: "Retry now"
                onClicked: {
                    manager.service.restart()
                    manager.service.refreshSnapshot()
                }
            }

            PillButton {
                kind: "outlined"
                text: "Copy start command"
                onClicked: {
                    Quickshell.execDetached(["dms", "cl", "copy", "systemctl --user start aria-download-manager"])
                    manager.service.notice("Copied")
                }
            }
        }
    }

    // ---- status bar -----------------------------------------------------------
    Rectangle {
        id: statusBar

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: manager.statusHeight
        //: A strip under a hairline, as board 9 ends the window.
        color: "transparent"

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 1
            color: Theme.outlineVariant
            opacity: 0.6
        }

        readonly property var totals: manager.service ? manager.service.activeTotals : ({})

        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingL

            StyledText {
                text: "↓ " + Fmt.speed(manager.service ? manager.service.downloadSpeed : 0)
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.primary
            }

            StyledText {
                text: "↑ " + Fmt.speed(manager.service ? manager.service.uploadSpeed : 0)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }

            StyledText {
                visible: (statusBar.totals.left || 0) > 0
                text: Fmt.bytes(statusBar.totals.left || 0) + " left" + (statusBar.totals.eta >= 0 ? " · " + Fmt.eta(statusBar.totals.eta) : "")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingL

            Row {
                spacing: 6

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 8
                    height: 8
                    radius: 4
                    color: !manager.online ? Theme.surfaceVariantText : (manager.service.aria2Running ? Theme.success : Theme.error)
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: !manager.online ? "Manager offline" : (manager.service.aria2Running ? "aria2c " + (manager.service.aria2.version || "") : "aria2c stopped")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                }
            }

            StyledText {
                text: "Automatic actions " + (manager.service && manager.service.rulesEnabled ? "on" : "off")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }
    }

    //: Confirmations rise into the bottom of the list, as in the popout.
    Feedback {
        service: manager.service
        anchors.horizontalCenter: centre.horizontalCenter
        anchors.bottom: statusBar.top
        anchors.bottomMargin: Theme.spacingM
        z: 10
    }
}
