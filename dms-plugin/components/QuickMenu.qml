import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Actions.js" as Actions
import "../lib/Fmt.js" as Fmt

//: Right-click menu for the bar pill. Shows what is happening first — the
//: overall progress and the few downloads that matter — then the handful of
//: things worth doing without opening the manager at all.
DankPopout {
    id: menu

    property var service: null

    //: The window and the popout are the widget's to open, so those go back out.
    signal windowRequested
    signal popoutRequested

    readonly property int padding: Theme.spacingS
    readonly property int rowHeight: 38
    readonly property int separatorHeight: Theme.spacingS + 1
    readonly property int downloadRowHeight: 44
    readonly property int bulkHeight: 64

    readonly property bool online: !!service && service.connected
    readonly property bool attention: online && !service.aria2Running
    readonly property bool busy: online && service.activeCount > 0
    readonly property var totals: service ? service.activeTotals : ({})
    readonly property bool showProgress: busy && totals.progress >= 0

    //: Running, paused and waiting downloads, a few at most. Nothing to list
    //: while aria2c is down: the rows would only offer buttons that cannot work.
    readonly property var listed: online && !attention && service ? service.topDownloads : []

    readonly property int statusHeight: {
        if (!online || attention)
            return 128
        return showProgress ? 80 : 64
    }

    readonly property int listHeight: listed.length > 0 ? listed.length * downloadRowHeight + Theme.spacingXS * 2 : 0

    //: The three bulk actions with their counts. Resume is worth offering with
    //: nothing paused — aria2 may still be holding downloads back — but pausing
    //: or purging nothing is a no-op.
    readonly property var bulk: {
        const svc = menu.service
        const usable = menu.online && !menu.attention
        const counts = {
            "pauseAll": usable ? svc.activeCount : 0,
            "resumeAll": usable ? svc.waitingCount : 0,
            "purge": usable ? svc.stoppedCount : 0
        }
        const shortLabel = {
            "pauseAll": "Pause all",
            "resumeAll": "Resume",
            "purge": "Clear"
        }
        return Actions.GLOBAL.map(action => ({
                                                 "icon": action.icon,
                                                 "text": shortLabel[action.id] + (counts[action.id] > 0 ? " · " + counts[action.id] : ""),
                                                 "enabled": usable && (action.id === "resumeAll" || counts[action.id] > 0),
                                                 "action": () => svc.post(action.path, null, action.ok)
                                             }))
    }

    readonly property var entries: {
        const svc = menu.service
        const on = menu.online
        const rows = [
            {
                "icon": "content_paste",
                "text": "Add link from clipboard",
                "enabled": on && !menu.attention,
                "action": () => clipboard.running = true
            },
            {
                "icon": "dashboard",
                "text": "Open manager",
                "action": () => menu.popoutRequested()
            },
            {
                "icon": "open_in_new",
                "text": "Open in window",
                "action": () => menu.windowRequested()
            },
            {
                "icon": "auto_fix_high",
                "text": "Automatic actions",
                "toggle": on && svc.rulesEnabled,
                "enabled": on,
                "action": () => svc.setRulesEnabled(!svc.rulesEnabled)
            }
        ]
        // While aria2c is down its restart is the headline button instead.
        if (on && !menu.attention) {
            rows.push({
                          "separator": true
                      })
            rows.push({
                          "icon": "restart_alt",
                          "text": "Restart aria2c",
                          "danger": true,
                          "muted": true,
                          "action": () => svc.post("/api/aria2/restart", null, "aria2c restarted")
                      })
        }
        return rows
    }

    function trigger(action) {
        menu.close()
        if (action)
            action()
    }

    //: wl-clipboard is not a hard dependency of the plugin, so a missing or
    //: unhelpful wl-paste has to say so rather than fail quietly.
    function addFromClipboard(text) {
        const url = (text || "").trim()
        if (!/^(https?|ftp|sftp|magnet):/i.test(url)) {
            ToastService.showError("Aria", "The clipboard does not hold a link that can be downloaded")
            return
        }
        menu.service.post("/api/downloads", {
                              "uris": [url]
                          }, "Added")
    }

    Process {
        id: clipboard

        command: ["wl-paste", "-n"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: menu.addFromClipboard(text)
        }

        onExited: exitCode => {
            if (exitCode !== 0)
                ToastService.showError("Aria", "Could not read the clipboard. Is wl-clipboard installed?")
        }
    }

    layerNamespace: "dms:plugins:aria-download-manager-quick"
    popupWidth: 300
    popupHeight: {
        let total = menu.padding * 2 + menu.statusHeight + menu.listHeight
        if (menu.online)
            total += menu.bulkHeight
        for (const entry of menu.entries)
            total += entry.separator ? menu.separatorHeight : menu.rowHeight
        return total
    }
    shouldBeVisible: false

    onBackgroundClicked: close()

    content: Component {
        Item {
            id: menuBody

            focus: true

            Component.onCompleted: {
                if (menu.shouldBeVisible)
                    forceActiveFocus()
            }

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    menu.close()
                    event.accepted = true
                }
            }

            Connections {
                target: menu
                function onShouldBeVisibleChanged() {
                    if (menu.shouldBeVisible)
                        Qt.callLater(() => menuBody.forceActiveFocus())
                }
            }

            Column {
                anchors.fill: parent
                anchors.margins: menu.padding
                spacing: 0

                // ---- what is happening ---------------------------------------
                Item {
                    width: parent.width
                    height: menu.statusHeight

                    // Running, held or idle.
                    Column {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: Theme.spacingS
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        visible: menu.online && !menu.attention
                        spacing: Theme.spacingXS

                        Item {
                            width: parent.width
                            height: headline.implicitHeight

                            StyledText {
                                id: headline

                                anchors.left: parent.left
                                anchors.right: rate.left
                                anchors.rightMargin: Theme.spacingS
                                text: {
                                    const svc = menu.service
                                    if (!svc)
                                        return ""
                                    if (menu.busy)
                                        return svc.activeCount + " downloading"
                                    if (svc.pausedCount > 0 && svc.queuedCount > 0)
                                        return svc.pausedCount + " paused, " + svc.queuedCount + " waiting"
                                    if (svc.pausedCount > 0)
                                        return svc.pausedCount + " paused"
                                    if (svc.queuedCount > 0)
                                        return svc.queuedCount + " waiting"
                                    return "Nothing downloading"
                                }
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Bold
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                            }

                            StyledText {
                                id: rate

                                anchors.right: parent.right
                                anchors.verticalCenter: headline.verticalCenter
                                visible: menu.busy
                                text: menu.service ? Fmt.speed(menu.service.downloadSpeed)
                                                     + (menu.totals.eta >= 0 ? " · " + Fmt.eta(menu.totals.eta) + " left" : "") : ""
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }

                        Rectangle {
                            width: parent.width
                            height: 6
                            radius: 3
                            visible: menu.showProgress
                            color: Theme.withAlpha(Theme.outline, 0.25)

                            Rectangle {
                                width: parent.width * Math.max(0, Math.min(1, menu.totals.progress || 0))
                                height: parent.height
                                radius: parent.radius
                                color: Theme.primary
                            }
                        }

                        StyledText {
                            width: parent.width
                            text: {
                                const svc = menu.service
                                if (!svc)
                                    return ""
                                const bits = []
                                if (menu.showProgress)
                                    bits.push(Fmt.bytes(menu.totals.completed) + " of " + Fmt.bytes(menu.totals.total))
                                if (menu.busy && svc.waitingCount > 0)
                                    bits.push(svc.waitingCount + " waiting")
                                if (svc.unseenFinished > 0)
                                    bits.push(svc.unseenFinished + " finished since you last looked")
                                else if (svc.completeCount > 0)
                                    bits.push(svc.completeCount + " finished")
                                return bits.join(" · ")
                            }
                            visible: text.length > 0
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            elide: Text.ElideRight
                        }
                    }

                    // aria2c down or the manager unreachable: the fix comes first.
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: Theme.spacingXS
                        visible: !menu.online || menu.attention
                        radius: Theme.cornerRadius
                        color: menu.attention ? Theme.withAlpha(Theme.error, 0.10) : Theme.surfaceContainerHigh

                        Column {
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingXS

                            Row {
                                spacing: Theme.spacingS

                                DankIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: menu.attention ? "error" : "cloud_off"
                                    size: 18
                                    color: menu.attention ? Theme.error : Theme.surfaceVariantText
                                }

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: menu.attention ? "aria2c stopped" : "Manager not running"
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                }
                            }

                            StyledText {
                                width: parent.width
                                text: {
                                    const svc = menu.service
                                    if (!svc)
                                        return ""
                                    if (menu.attention)
                                        return svc.aria2.last_error || "See the event log under Settings."
                                    return "Nothing answered on " + svc.socketPath
                                }
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                elide: Text.ElideMiddle
                                maximumLineCount: 1
                            }

                            Item {
                                width: 1
                                height: Theme.spacingXS
                            }

                            DankButton {
                                text: menu.attention ? "Restart aria2c" : "Retry now"
                                iconName: menu.attention ? "restart_alt" : "refresh"
                                buttonHeight: 34
                                backgroundColor: Theme.primary
                                textColor: Theme.onPrimary
                                onClicked: {
                                    const svc = menu.service
                                    if (menu.attention) {
                                        menu.trigger(() => svc.post("/api/aria2/restart", null, "aria2c restarted"))
                                    } else {
                                        svc.restart()
                                        svc.refreshSnapshot()
                                    }
                                }
                            }
                        }
                    }
                }

                // ---- the downloads that matter ------------------------------
                Rectangle {
                    width: parent.width
                    height: menu.listHeight
                    visible: menu.listHeight > 0
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    Column {
                        anchors.fill: parent
                        anchors.topMargin: Theme.spacingXS
                        anchors.bottomMargin: Theme.spacingXS

                        Repeater {
                            model: menu.listed

                            Item {
                                id: dlRow

                                required property var modelData

                                readonly property bool running: modelData.status === "active"
                                readonly property real fraction: Math.max(0, Math.min(1, (modelData.progress || 0) / 100))

                                width: parent.width
                                height: menu.downloadRowHeight

                                StyledText {
                                    id: dlName

                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.right: dlPct.left
                                    anchors.rightMargin: Theme.spacingS
                                    anchors.top: parent.top
                                    anchors.topMargin: Theme.spacingS
                                    text: dlRow.modelData.name || dlRow.modelData.gid
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: dlRow.running ? Theme.surfaceText : Theme.surfaceVariantText
                                    elide: Text.ElideMiddle
                                    wrapMode: Text.NoWrap
                                }

                                StyledText {
                                    id: dlPct

                                    anchors.right: dlButton.left
                                    anchors.rightMargin: Theme.spacingXS
                                    anchors.verticalCenter: dlName.verticalCenter
                                    text: {
                                        const pct = Math.floor(dlRow.fraction * 100) + "%"
                                        if (dlRow.modelData.status === "paused")
                                            return "Paused · " + pct
                                        if (dlRow.modelData.status === "waiting")
                                            return "Waiting"
                                        return pct
                                    }
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }

                                Rectangle {
                                    anchors.left: dlName.left
                                    anchors.right: dlPct.right
                                    anchors.top: dlName.bottom
                                    anchors.topMargin: 6
                                    height: 3
                                    radius: 1.5
                                    color: Theme.withAlpha(Theme.outline, 0.25)

                                    Rectangle {
                                        width: parent.width * dlRow.fraction
                                        height: parent.height
                                        radius: parent.radius
                                        color: dlRow.running ? Theme.primary : Theme.surfaceVariantText
                                    }
                                }

                                DankActionButton {
                                    id: dlButton

                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.spacingXS
                                    anchors.verticalCenter: parent.verticalCenter
                                    buttonSize: 30
                                    iconSize: Theme.iconSizeSmall
                                    iconName: dlRow.running ? "pause" : "play_arrow"
                                    tooltipText: dlRow.running ? "Pause" : "Resume"
                                    onClicked: menu.service.post("/api/download/" + dlRow.modelData.gid
                                                                 + (dlRow.running ? "/pause" : "/resume"), null, "")
                                }
                            }
                        }
                    }
                }

                // ---- bulk actions -------------------------------------------
                Item {
                    width: parent.width
                    height: menu.online ? menu.bulkHeight : 0
                    visible: menu.online

                    Row {
                        anchors.fill: parent
                        anchors.topMargin: Theme.spacingS
                        anchors.bottomMargin: 2
                        spacing: Theme.spacingXS

                        Repeater {
                            model: menu.bulk

                            Rectangle {
                                id: bulkButton

                                required property var modelData

                                width: (parent.width - Theme.spacingXS * 2) / 3
                                height: parent.height
                                radius: Theme.cornerRadius
                                color: bulkArea.containsMouse && modelData.enabled ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                                opacity: modelData.enabled ? 1 : 0.45

                                Column {
                                    anchors.centerIn: parent
                                    spacing: 2

                                    DankIcon {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        name: bulkButton.modelData.icon
                                        size: 18
                                        color: Theme.surfaceText
                                    }

                                    StyledText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: bulkButton.modelData.text
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.surfaceText
                                    }
                                }

                                MouseArea {
                                    id: bulkArea

                                    anchors.fill: parent
                                    hoverEnabled: true
                                    enabled: bulkButton.modelData.enabled
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: menu.trigger(bulkButton.modelData.action)
                                }
                            }
                        }
                    }
                }

                // ---- the rest -----------------------------------------------
                Repeater {
                    model: menu.entries

                    QuickMenuRow {
                        required property var modelData

                        width: parent.width
                        entry: modelData
                        rowHeight: menu.rowHeight
                        separatorHeight: menu.separatorHeight
                        // A toggle stays open so the switch can be seen to move.
                        onTriggered: {
                            if (modelData.toggle !== undefined) {
                                if (modelData.action)
                                    modelData.action()
                            } else {
                                menu.trigger(modelData.action)
                            }
                        }
                    }
                }
            }
        }
    }
}
