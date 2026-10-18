import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Actions.js" as Actions
import "../lib/Fmt.js" as Fmt

//: Right-click menu for the bar pill (boards 3 and 11). Shows what is
//: happening first — the overall progress and the few downloads that matter —
//: then the handful of things worth doing without opening the manager.
DankPopout {
    id: menu

    property var service: null

    //: The window and the popout are the widget's to open, so those go back out.
    signal windowRequested
    signal popoutRequested

    // The board's measurements: a 340 px menu, 10 px padding, 6 px between
    // every block and row.
    readonly property int padding: 10
    readonly property int gap: 6
    readonly property int rowHeight: 38
    readonly property int clipRowHeight: 48
    readonly property int separatorHeight: 9
    readonly property int downloadRowHeight: 41
    readonly property int moreHeight: 30
    readonly property int bulkHeight: 64

    readonly property bool online: !!service && service.connected
    readonly property bool attention: online && !service.aria2Running
    readonly property bool busy: online && service.activeCount > 0
    readonly property var totals: service ? service.activeTotals : ({})
    readonly property bool showProgress: busy && totals.progress >= 0

    //: Running, paused and waiting downloads, a few at most. Nothing to list
    //: while aria2c is down: the rows would only offer buttons that cannot work.
    readonly property var listed: online && !attention && service ? service.topDownloads : []
    //: Running and held downloads the list has no room for.
    readonly property int unlisted: online && !attention && service ? Math.max(0, service.activeCount + service.waitingCount - listed.length) : 0

    readonly property string headline: {
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

    readonly property string subline: {
        const svc = menu.service
        if (!svc)
            return ""
        const bits = []
        if (menu.showProgress)
            bits.push(Fmt.bytes(menu.totals.completed) + " of " + Fmt.bytes(menu.totals.total))
        if (svc.pausedCount > 0 && menu.busy)
            bits.push(svc.pausedCount + " paused")
        if (svc.queuedCount > 0 && menu.busy)
            bits.push(svc.queuedCount + " waiting")
        if (svc.completeCount > 0)
            bits.push(svc.completeCount + " finished")
        if (!menu.busy && svc.pausedCount > 0 && svc.queuedCount === 0 && bits.length === 0)
            bits.push(svc.pausedCount + " paused")
        return bits.join(" · ")
    }

    //: Header height, from the board: 10 px above, the 17 px headline, the
    //: bar and the line under it with 8 px between, 12 px below.
    readonly property int statusHeight: 10 + 23 + (showProgress ? 8 + 6 : 0) + (subline ? 8 + 16 : 0) + 12
    readonly property int listHeight: listed.length > 0 ? listed.length * downloadRowHeight + 8 + (unlisted > 0 ? moreHeight : 0) : 0
    readonly property int offlineHeight: 168
    readonly property int downHeight: 132

    // ---- clipboard preview ---------------------------------------------------
    //: Read once each time the menu opens, so the row can show what it would
    //: add — a wrong clipboard is caught before the click, not after.
    property string clipText: ""
    property bool clipRead: false

    readonly property string clipLink: {
        const text = clipText.trim()
        return /^(https?|ftp|sftp|magnet):\S+$/i.test(text) ? text : ""
    }

    readonly property string clipPreview: {
        if (!clipRead)
            return "Reading the clipboard…"
        if (!clipLink)
            return "No link on the clipboard"
        return Fmt.shortLink(clipLink)
    }

    onShouldBeVisibleChanged: {
        if (!shouldBeVisible)
            return
        menu.clipText = ""
        menu.clipRead = false
        peek.running = true
    }

    //: wl-paste when it is installed (asking for text, so an image on the
    //: clipboard is skipped), DMS's own clipboard otherwise. Capped: a link
    //: is short, and the clipboard may hold a picture.
    Process {
        id: peek

        command: ["sh", "-c", "{ command -v wl-paste >/dev/null && wl-paste -n -t text 2>/dev/null || dms cl paste 2>/dev/null; } | head -c 8192"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                menu.clipText = text
                menu.clipRead = true
            }
        }

        onExited: exitCode => {
            // An empty clipboard exits non-zero too; either way there is no link.
            menu.clipRead = true
        }
    }

    //: The three bulk actions with their counts. Resume is worth offering with
    //: nothing paused — aria2 may still be holding downloads back — but pausing
    //: or purging nothing is a no-op.
    readonly property var bulk: {
        const svc = menu.service
        const usable = menu.online && !menu.attention
        const counts = {
            "pauseAll": usable ? svc.activeCount : 0,
            "resumeAll": usable ? svc.waitingCount : 0,
            "purge": usable ? svc.clearableCount : 0
        }
        const shortLabel = {
            "pauseAll": "Pause all",
            "resumeAll": "Resume",
            "purge": "Clear"
        }
        return Actions.GLOBAL.map(action => ({
                                                 "icon": action.icon,
                                                 "text": action.id === "purge" && menu.clearArmed ? "Sure? · " + counts.purge
                                                         : shortLabel[action.id] + (counts[action.id] > 0 ? " · " + counts[action.id] : ""),
                                                 "enabled": usable && (action.id === "resumeAll" || counts[action.id] > 0),
                                                 "confirm": action.id === "purge",
                                                 "action": () => action.id === "pauseAll" ? svc.pauseAllWithUndo(action.ok)
                                                                 : action.id === "purge" ? svc.clearFinished() : svc.post(action.path, null, action.ok)
                                             }))
    }

    readonly property var clipEntry: ({
            "icon": "content_paste",
            "text": "Add link from clipboard",
            "subtitle": menu.clipPreview,
            "height": menu.clipRowHeight,
            "enabled": menu.clipLink !== "",
            "highlight": menu.listed.length === 0,
            "action": () => menu.addFromClipboard(menu.clipLink)
        })

    //: With nothing to list, the clipboard row leads, raised, above the bulk
    //: buttons (board 11); with downloads listed it follows them (board 3).
    readonly property bool clipFirst: online && !attention && listed.length === 0

    readonly property var entries: {
        const svc = menu.service
        // Offline, the status card's Retry is the only thing worth doing.
        if (!menu.online)
            return []
        // aria2c down: its restart is the headline button; what is left is
        // finding out why.
        if (menu.attention)
            return [
                        {
                            "icon": "receipt_long",
                            "text": "Open the event log",
                            "action": () => {
                                svc.requestedLog = true
                                svc.requestedTab = svc.settingsTabIndex
                                menu.popoutRequested()
                            }
                        },
                        {
                            "icon": "open_in_new",
                            "text": "Open in window",
                            "action": () => menu.windowRequested()
                        }
                    ]
        const rows = menu.clipFirst ? [] : [menu.clipEntry]
        return rows.concat([
                               {
                                   "icon": "open_in_new",
                                   "text": "Open in window",
                                   "action": () => menu.windowRequested()
                               },
                               {
                                   "icon": "auto_fix_high",
                                   "text": "Automatic actions",
                                   "toggle": svc.rulesEnabled,
                                   "action": () => svc.setRulesEnabled(!svc.rulesEnabled)
                               },
                               //: The one-off for when everything is done; each
                               //: switch turns the other off.
                               {
                                   "icon": "bedtime",
                                   "text": "Suspend when done",
                                   "toggle": svc.afterAll.action === "suspend",
                                   "action": () => svc.setAfterAll(svc.afterAll.action === "suspend" ? "" : "suspend")
                               },
                               {
                                   "icon": "power_settings_new",
                                   "text": "Shut down when done",
                                   "toggle": svc.afterAll.action === "shutdown",
                                   "action": () => svc.setAfterAll(svc.afterAll.action === "shutdown" ? "" : "shutdown")
                               },
                               {
                                   "separator": true
                               },
                               {
                                   "icon": "restart_alt",
                                   "text": "Restart aria2c",
                                   "danger": true,
                                   "muted": true,
                                   "height": 36,
                                   "action": () => svc.restartAria2()
                               }
                           ])
    }

    //: Clear asks for a second press: one stray click would empty the list.
    property bool clearArmed: false

    Timer {
        id: clearArmTimer

        interval: 4000
        onTriggered: menu.clearArmed = false
    }

    onPopoutClosed: clearArmed = false

    function trigger(action) {
        menu.close()
        if (action)
            action()
    }

    //: The row is greyed out without a link, so this only sees real ones.
    function addFromClipboard(url) {
        if (!url)
            return
        menu.service.post("/api/downloads", {
                              "uris": [url]
                          }, "Added")
    }

    layerNamespace: "dms:plugins:aria-download-manager-quick"
    popupWidth: 340
    popupHeight: {
        if (!menu.online)
            return menu.offlineHeight
        const blocks = [menu.attention ? menu.downHeight : menu.statusHeight]
        if (menu.listHeight > 0)
            blocks.push(menu.listHeight)
        if (menu.clipFirst)
            blocks.push(menu.clipRowHeight)
        blocks.push(menu.bulkHeight)
        for (const entry of menu.entries)
            blocks.push(entry.separator ? menu.separatorHeight : (entry.height || menu.rowHeight))
        return menu.padding * 2 + blocks.reduce((a, b) => a + b, 0) + menu.gap * (blocks.length - 1)
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

            // ---- the manager is not there: the one thing to do -----------------
            Column {
                anchors.fill: parent
                anchors.margins: 18
                visible: !menu.online
                spacing: 10

                Row {
                    spacing: 10

                    DankIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "cloud_off"
                        size: 22
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Manager not running"
                        font.pixelSize: Theme.fontSizeMedium + 1
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                    }
                }

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    textFormat: Text.StyledText
                    text: "Nothing answered on <font face=\"monospace\" color=\"" + Theme.surfaceText + "\">"
                          + (menu.service ? menu.service.socketPath : "") + "</font>. Start it with run.sh or the systemd user unit."
                    font.pixelSize: Theme.fontSizeSmall + 1
                    lineHeight: 1.3
                    color: Theme.surfaceVariantText
                }

                Row {
                    topPadding: 4
                    spacing: 8

                    PillButton {
                        kind: "filled"
                        text: "Retry now"
                        onClicked: {
                            menu.service.restart()
                            menu.service.refreshSnapshot()
                        }
                    }

                    PillButton {
                        kind: "outlined"
                        text: "Copy socket path"
                        onClicked: {
                            Quickshell.execDetached(["dms", "cl", "copy", menu.service.socketPath])
                            ToastService.showInfo("Socket path copied")
                        }
                    }
                }
            }

            Column {
                anchors.fill: parent
                anchors.margins: menu.padding
                visible: menu.online
                spacing: menu.gap

                // ---- what is happening -----------------------------------------
                Item {
                    width: parent.width
                    height: menu.statusHeight
                    visible: !menu.attention

                    Column {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        anchors.topMargin: 10
                        spacing: 8

                        Item {
                            width: parent.width
                            height: 23

                            StyledText {
                                anchors.left: parent.left
                                anchors.right: rate.left
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                text: menu.headline
                                font.pixelSize: Theme.fontSizeLarge + 1
                                font.weight: Font.DemiBold
                                color: Theme.surfaceText
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                            }

                            StyledText {
                                id: rate

                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                visible: menu.busy
                                text: menu.service ? Fmt.speed(menu.service.downloadSpeed)
                                                     + (menu.totals.eta >= 0 ? " · " + Fmt.eta(menu.totals.eta) + " left" : "") : ""
                                font.pixelSize: Theme.fontSizeSmall + 1
                                color: Theme.surfaceVariantText
                            }
                        }

                        Rectangle {
                            width: parent.width
                            height: 6
                            radius: 3
                            visible: menu.showProgress
                            color: Theme.surfaceContainerHighest

                            Rectangle {
                                width: parent.width * Math.max(0, Math.min(1, menu.totals.progress || 0))
                                height: parent.height
                                radius: parent.radius
                                color: Theme.primary
                            }
                        }

                        StyledText {
                            width: parent.width
                            visible: text.length > 0
                            text: menu.subline
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.NoWrap
                            elide: Text.ElideRight
                        }
                    }
                }

                // ---- aria2c down: the fix leads --------------------------------
                Item {
                    width: parent.width
                    height: menu.downHeight
                    visible: menu.attention

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 4
                        radius: 12
                        color: Theme.withAlpha(Theme.error, 0.10)

                        Column {
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 8

                            Row {
                                spacing: 10

                                DankIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: "error"
                                    size: 20
                                    color: Theme.error
                                }

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "aria2c stopped"
                                    font.pixelSize: Theme.fontSizeMedium + 1
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }
                            }

                            StyledText {
                                width: parent.width
                                text: menu.service ? (menu.service.aria2.last_error || "See the event log for why.") : ""
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }

                            PillButton {
                                size: 34
                                kind: "filled"
                                icon: "restart_alt"
                                text: menu.service && menu.service.restarting === "aria2c" ? "Restarting…" : "Restart aria2c"
                                busy: !!menu.service && menu.service.restarting === "aria2c"
                                onClicked: menu.service.restartAria2()
                            }
                        }
                    }
                }

                // ---- the downloads that matter --------------------------------
                Rectangle {
                    width: parent.width
                    height: menu.listHeight
                    visible: menu.listHeight > 0
                    radius: 12
                    color: Theme.surfaceContainerHigh

                    Column {
                        anchors.fill: parent
                        anchors.margins: 4

                        Repeater {
                            model: menu.listed

                            Item {
                                id: dlRow

                                required property var modelData

                                readonly property bool running: modelData.status === "active"
                                readonly property real fraction: Math.max(0, Math.min(1, (modelData.progress || 0) / 100))

                                width: parent.width
                                height: menu.downloadRowHeight

                                Column {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.right: dlButton.left
                                    anchors.rightMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 5

                                    Item {
                                        width: parent.width
                                        height: dlName.implicitHeight

                                        StyledText {
                                            id: dlName

                                            anchors.left: parent.left
                                            anchors.right: dlPct.left
                                            anchors.rightMargin: 8
                                            text: dlRow.modelData.name || dlRow.modelData.gid
                                            font.pixelSize: Theme.fontSizeSmall + 1
                                            color: dlRow.running ? Theme.surfaceText : Theme.surfaceVariantText
                                            elide: Text.ElideRight
                                            wrapMode: Text.NoWrap
                                        }

                                        StyledText {
                                            id: dlPct

                                            anchors.right: parent.right
                                            text: {
                                                const pct = Math.floor(dlRow.fraction * 100) + "%"
                                                if (dlRow.modelData.status === "paused")
                                                    return "Paused · " + pct
                                                if (dlRow.modelData.status === "waiting")
                                                    return "Waiting"
                                                return pct
                                            }
                                            font.pixelSize: Theme.fontSizeSmall + 1
                                            color: Theme.surfaceVariantText
                                        }
                                    }

                                    Rectangle {
                                        width: parent.width
                                        height: 3
                                        radius: 1.5
                                        color: Theme.outlineVariant

                                        Rectangle {
                                            width: parent.width * dlRow.fraction
                                            height: parent.height
                                            radius: parent.radius
                                            color: dlRow.running ? Theme.primary : Theme.surfaceVariantText
                                        }
                                    }
                                }

                                DankActionButton {
                                    id: dlButton

                                    anchors.right: parent.right
                                    anchors.rightMargin: 2
                                    anchors.verticalCenter: parent.verticalCenter
                                    buttonSize: 32
                                    iconSize: 18
                                    iconName: dlRow.running ? "pause" : "play_arrow"
                                    iconColor: Theme.surfaceText
                                    tooltipText: (dlRow.running ? "Pause " : "Resume ") + (dlRow.modelData.name || "")
                                    onClicked: menu.service.setPaused(dlRow.modelData.gid, dlRow.running)
                                }
                            }
                        }

                        //: The list stops at three; the rest is a click away.
                        Item {
                            width: parent.width
                            height: menu.moreHeight
                            visible: menu.unlisted > 0

                            Row {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 6

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "+" + menu.unlisted + " more · Open manager"
                                    font.pixelSize: Theme.fontSizeSmall + 1
                                    color: Theme.primary
                                    font.underline: moreArea.containsMouse
                                }

                                DankIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: "chevron_right"
                                    size: 16
                                    color: Theme.primary
                                }
                            }

                            MouseArea {
                                id: moreArea

                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: menu.trigger(() => menu.popoutRequested())
                            }
                        }
                    }
                }

                // Nothing listed: the clipboard row leads, raised.
                QuickMenuRow {
                    width: parent.width
                    visible: menu.clipFirst
                    entry: menu.clipEntry
                    rowHeight: menu.clipRowHeight
                    onTriggered: menu.trigger(menu.clipEntry.action)
                }

                // ---- bulk actions ---------------------------------------------
                Item {
                    width: parent.width
                    height: menu.bulkHeight

                    Row {
                        anchors.fill: parent
                        anchors.topMargin: 4
                        anchors.bottomMargin: 4
                        spacing: 6
                        opacity: menu.attention ? 0.5 : 1

                        Repeater {
                            model: menu.bulk

                            Rectangle {
                                id: bulkButton

                                required property var modelData

                                width: (parent.width - 12) / 3
                                height: parent.height
                                radius: 12
                                color: bulkButton.modelData.enabled ? Theme.surfaceContainerHigh : Theme.surfaceContainer

                                Rectangle {
                                    anchors.fill: parent
                                    radius: parent.radius
                                    color: Theme.surfaceText
                                    opacity: bulkArea.containsMouse && bulkButton.modelData.enabled ? 0.08 : 0
                                }

                                Column {
                                    anchors.centerIn: parent
                                    spacing: 3

                                    DankIcon {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        name: bulkButton.modelData.icon
                                        size: 20
                                        color: bulkButton.modelData.enabled ? Theme.surfaceText : Theme.outline
                                    }

                                    StyledText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: bulkButton.modelData.text
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: bulkButton.modelData.enabled ? Theme.surfaceText : Theme.outline
                                    }
                                }

                                MouseArea {
                                    id: bulkArea

                                    anchors.fill: parent
                                    hoverEnabled: true
                                    enabled: bulkButton.modelData.enabled
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (bulkButton.modelData.confirm && !menu.clearArmed) {
                                            menu.clearArmed = true
                                            clearArmTimer.restart()
                                            return
                                        }
                                        menu.trigger(bulkButton.modelData.action)
                                    }
                                }
                            }
                        }
                    }
                }

                // ---- the rest -------------------------------------------------
                Repeater {
                    model: menu.entries

                    QuickMenuRow {
                        required property var modelData

                        width: parent.width
                        entry: modelData
                        rowHeight: modelData.height || menu.rowHeight
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
