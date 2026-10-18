import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt
import "../lib/Layout.js" as Layout

Item {
    id: tab

    property var service: null
    property string filter: "all"
    property string search: ""
    property string expandedGid: ""
    property bool adding: false

    //: Hosted by the wide window: the rail there holds the filters, so the
    //: chips step aside, and a click picks a row for the detail pane beside
    //: the list instead of unfolding it in place.
    property bool showChips: true
    property bool pickMode: false
    property string selectedGid: ""

    readonly property int scrollbarGutter: Layout.SCROLLBAR_GUTTER

    // ---- bulk selection --------------------------------------------------
    //: gid -> true. A plain object rather than a list so a row can test its own
    //: membership without scanning, and so reassigning it is one signal.
    property var selection: ({})
    property bool selecting: false
    property bool confirmingBulkRemove: false
    //: Clearing history cannot be undone, so it asks first.
    property bool confirmingClearHistory: false

    //: A selection can mix the two cases, so they are counted separately: the
    //: unfinished ones are cleaned up without asking, and only the finished
    //: ones raise the question of whether to keep what was downloaded.
    readonly property var selectedFinished: selectedLive.filter(g => (byGid[g] || {}).status === "complete")
    readonly property var selectedUnfinished: selectedLive.filter(g => (byGid[g] || {}).status !== "complete")

    readonly property var selectedGids: Object.keys(selection).filter(g => selection[g])
    //: Live downloads, and finished ones aria2 forgot ("h:" + key), which
    //: can only be forgotten.
    readonly property var selectedLive: selectedGids.filter(g => g.indexOf("h:") !== 0)
    readonly property var selectedPast: selectedGids.filter(g => g.indexOf("h:") === 0)
    readonly property int selectedCount: selectedGids.length

    function isSelected(gid) {
        return selection[gid] === true
    }

    //: The row last clicked, where a Shift-click range starts from.
    property string lastClicked: ""

    //: `range` (Shift held) selects every visible row between the last one
    //: clicked and this one, inclusive.
    function toggleSelection(gid, range) {
        const next = Object.assign({}, selection)
        const from = gids.indexOf(lastClicked)
        const to = gids.indexOf(gid)
        if (range && from >= 0 && to >= 0) {
            for (let i = Math.min(from, to); i <= Math.max(from, to); i++)
                next[gids[i]] = true
        } else if (next[gid]) {
            delete next[gid]
        } else {
            next[gid] = true
        }
        lastClicked = gid
        selection = next
    }

    function clearSelection() {
        selection = ({})
        confirmingBulkRemove = false
    }

    function selectAllVisible() {
        const next = ({})
        for (const gid of gids)
            next[gid] = true
        selection = next
    }

    //: Selection only means anything against rows that are on screen; changing
    //: the filter or leaving selection mode drops it rather than acting later
    //: on downloads the user can no longer see.
    onFilterChanged: {
        clearSelection()
        confirmingClearHistory = false
    }
    onSelectingChanged: {
        if (!selecting) {
            clearSelection()
            lastClicked = ""
        } else {
            // A tick is a tick: no row stays open while picking.
            expandedGid = ""
            // Esc leaves selection mode; the tab needs focus to hear it.
            tab.forceActiveFocus()
        }
    }

    //: A near miss in the search box: the word in a download's name that is
    //: one or two edits away from what was typed.
    readonly property string suggestion: {
        const needle = search.toLowerCase()
        if (needle.length < 4 || !service)
            return ""
        const distance = (a, b) => {
            const row = Array.from({
                                       "length": b.length + 1
                                   }, (_, k) => k)
            for (let x = 1; x <= a.length; x++) {
                let prev = row[0]
                row[0] = x
                for (let y = 1; y <= b.length; y++) {
                    const keep = row[y]
                    row[y] = Math.min(row[y] + 1, row[y - 1] + 1, prev + (a[x - 1] === b[y - 1] ? 0 : 1))
                    prev = keep
                }
            }
            return row[b.length]
        }
        let best = ""
        let bestScore = 3
        for (const d of service.downloads) {
            for (const word of String(d.name || "").toLowerCase().split(/[^a-z0-9]+/)) {
                if (word.length < 3)
                    continue
                const score = distance(needle, word)
                if (score > 0 && score < bestScore) {
                    best = word
                    bestScore = score
                }
            }
        }
        return best
    }

    //: Ctrl V anywhere in the tab pastes the clipboard's links into Add.
    focus: true
    Keys.onPressed: event => {
        if (event.key === Qt.Key_V && (event.modifiers & Qt.ControlModifier)) {
            tab.pasteFromClipboard()
            event.accepted = true
        }
    }

    Keys.onEscapePressed: event => {
        if (tab.confirmingBulkRemove) {
            tab.confirmingBulkRemove = false
            event.accepted = true
        } else if (tab.selecting) {
            tab.selecting = false
            event.accepted = true
        } else {
            event.accepted = false
        }
    }

    function runBulk(action) {
        if (!selectedLive.length)
            return
        service.bulk(action, selectedLive, false, () => tab.clearSelection())
    }

    //: Finished ones aria2 forgot leave the record; their files stay.
    function forgetPast(keys) {
        let waiting = keys.length
        for (const id of keys)
            service.request("POST", "/api/history/remove", {
                                "key": id.slice(2)
                            }, () => {
                                if (--waiting === 0) {
                                    tab.service.notice(keys.length === 1 ? "Forgotten" : "Forgot " + keys.length)
                                    tab.service.loadHistory()
                                }
                            })
    }

    //: `keepFinishedFiles` only governs the finished downloads; a part file is
    //: never worth keeping, so those always go with their rows.
    function runBulkRemove(keepFinishedFiles) {
        const unfinished = selectedUnfinished
        const finished = selectedFinished
        const past = selectedPast
        if (unfinished.length)
            service.bulk("remove", unfinished, true)
        if (finished.length)
            service.bulk("remove", finished, !keepFinishedFiles)
        if (past.length)
            forgetPast(past)
        tab.confirmingBulkRemove = false
        tab.clearSelection()
    }

    //: Nothing finished in the selection means nothing to ask about.
    function askBulkRemove() {
        if (!selectedFinished.length) {
            runBulkRemove(false)
            return
        }
        confirmingBulkRemove = true
    }

    // ---- finished downloads aria2 no longer holds ---------------------------
    //: The manager's history, less what the live list still shows (see the
    //: service): listed as "h:" + their key under Done, Failed and All.
    readonly property var pastEntries: service ? service.pastEntries : []
    readonly property var pastById: {
        const out = ({})
        for (const e of pastEntries)
            out["h:" + e.key] = e
        return out
    }

    function pastStatus(entry) {
        return entry.status === "error" ? "error" : "complete"
    }

    readonly property int pastDone: service ? service.pastDone : 0
    readonly property int pastFailed: service ? service.pastFailed : 0

    // ---- sort ------------------------------------------------------------
    //: "queue", "added" or "finished", and whether it runs backwards. Kept in
    //: the plugin's settings, like the Settings tab's mode, so the list opens
    //: the way it was left. The manager stamps addedAt / finishedAt on every
    //: row, since aria2 itself keeps no timestamps.
    readonly property var sortFields: ["queue", "added", "finished"]
    readonly property var sortLabels: ["Queue order", "Date added", "Date completed"]
    //: Each field starts the way people expect it: the queue from the front,
    //: dates newest first.
    readonly property var sortDefaultDesc: ({
            "queue": false,
            "added": true,
            "finished": true
        })
    readonly property string storedSort: {
        const field = service ? service.cfg.downloadSort : ""
        return sortFields.indexOf(field) >= 0 ? field : "queue"
    }
    readonly property string sortField: storedSort
    readonly property bool sortDesc: service ? service.cfg.downloadSortDesc === true : false

    function setSort(field, desc) {
        PluginService.savePluginData("ariaDownloadManager", "downloadSort", field)
        PluginService.savePluginData("ariaDownloadManager", "downloadSortDesc", desc)
    }

    onSortFieldChanged: recompute()
    onSortDescChanged: recompute()

    // gid -> row, so a delegate can bind to live values without the list model
    // itself churning every tick.
    readonly property var byGid: {
        const map = ({})
        const list = service ? service.downloads : []
        for (var i = 0; i < list.length; i++)
            map[list[i].gid] = list[i]
        return map
    }

    // Only reassigned when membership or order actually changes, so delegates
    // (and any expanded detail panel) survive the 1 Hz state stream.
    property var gids: []

    function recompute() {
        if (!service)
            return

        const rank = {
            "active": 0,
            "paused": 0,
            "waiting": 1,
            "error": 2,
            "complete": 3,
            "removed": 4
        }
        const needle = search.toLowerCase()
        const list = service.downloads.filter(d => {
            if (filter !== "all" && d.status !== filter)
                return false
            if (needle && d.name.toLowerCase().indexOf(needle) === -1)
                return false
            return true
        })

        const rankOf = d => service.isActing(d.gid) ? 0 : (rank[d.status] !== undefined ? rank[d.status] : 9)
        const byQueue = (a, b) => (rankOf(a) - rankOf(b)) || ((a.queuePosition || 0) - (b.queuePosition || 0))
        const dir = sortDesc ? -1 : 1
        if (sortField === "queue") {
            list.sort((a, b) => dir * byQueue(a, b))
        } else {
            const key = sortField === "added" ? "addedAt" : "finishedAt"
            list.sort((a, b) => {
                // Nothing to order by (not finished yet) sinks to the end
                // either way, in queue order, rather than flipping to the top.
                const x = a[key], y = b[key]
                const xNone = x === undefined || x === null
                const yNone = y === undefined || y === null
                if (xNone || yNone)
                    return (xNone - yNone) || byQueue(a, b)
                return dir * (x - y) || byQueue(a, b)
            })
        }

        // Finished ones aria2 has forgotten: after the queue, newest first, or
        // among the live ones by the same date.
        const past = pastEntries.filter(e => (filter === "all" || pastStatus(e) === filter)
                                            && (!needle || String(e.name || e.key || "").toLowerCase().indexOf(needle) >= 0))
        let next
        if (sortField === "queue") {
            past.sort((a, b) => (b.finished_at || 0) - (a.finished_at || 0))
            next = list.map(d => d.gid).concat(past.map(e => "h:" + e.key))
        } else {
            const live = sortField === "added" ? "addedAt" : "finishedAt"
            const old = sortField === "added" ? "added_at" : "finished_at"
            const items = list.map(d => ({
                                             "id": d.gid,
                                             "at": d[live]
                                         })).concat(past.map(e => ({
                                                                       "id": "h:" + e.key,
                                                                       "at": e[old] || e.first_seen
                                                                   })))
            items.sort((a, b) => {
                const xNone = a.at === undefined || a.at === null
                const yNone = b.at === undefined || b.at === null
                if (xNone || yNone)
                    return xNone - yNone
                return dir * (a.at - b.at)
            })
            next = items.map(i => i.id)
        }
        if (next.join(",") !== gids.join(","))
            gids = next
    }

    function setFilter(name) {
        filter = name
        recompute()
    }

    onSearchChanged: recompute()

    Component.onCompleted: {
        if (service)
            service.loadHistory()
        recompute()
    }

    //: A download that finishes (or fails) is recorded: read the history
    //: again, so it stays listed once aria2 forgets it.
    property int finishedSeen: -1

    Connections {
        target: tab.service
        function onSnapshotChanged() {
            const c = tab.service.counts || ({})
            const finished = (c.complete || 0) + (c.error || 0)
            if (finished !== tab.finishedSeen) {
                tab.finishedSeen = finished
                tab.service.loadHistory()
            }
            tab.recompute()
        }
        function onHistoryLoaded() {
            tab.recompute()
        }
    }

    // ---- filters ---------------------------------------------------------
    FilterChips {
        id: chips

        visible: tab.showChips
        height: visible ? implicitHeight : 0
        width: parent.width - tab.scrollbarGutter
        current: tab.filter
        model: {
            const c = tab.service ? tab.service.counts : ({})
            return [
                {
                    "label": "All",
                    "value": "all",
                    "count": (c.total || 0) + tab.pastEntries.length
                },
                {
                    "label": "Active",
                    "value": "active",
                    "count": c.active || 0
                },
                {
                    "label": "Queued",
                    "value": "waiting",
                    "count": c.waiting || 0
                },
                {
                    "label": "Paused",
                    "value": "paused",
                    "count": c.paused || 0
                },
                {
                    "label": "Done",
                    "value": "complete",
                    "count": (c.complete || 0) + tab.pastDone
                },
                {
                    "label": "Failed",
                    "value": "error",
                    "count": (c.error || 0) + tab.pastFailed
                }
            ]
        }

        onPicked: value => tab.setFilter(value)
    }

    //: The board's toolbar: a search pill, the order as a pill that opens a
    //: menu, select as a round icon, and Add as the one filled button.
    Item {
        id: searchRow

        anchors.top: tab.showChips ? chips.bottom : parent.top
        anchors.topMargin: tab.showChips ? 12 : 0
        width: parent.width - tab.scrollbarGutter
        height: 40

        //: While selecting, the selection bar takes this row's place rather
        //: than stacking under it.
        readonly property bool tools: !tab.selecting

        SearchPill {
            id: searchField

            visible: searchRow.tools
            anchors.left: parent.left
            anchors.right: sortPill.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "Search downloads"
            onTextChanged: tab.search = text
        }

        //: The order, said in one word; the menu holds the choices and the
        //: direction.
        PillButton {
            id: sortPill

            readonly property var shortLabels: ({
                    "queue": "Queue",
                    "added": tab.sortDesc ? "Newest" : "Oldest",
                    "finished": tab.sortDesc ? "Newest" : "Oldest"
                })

            visible: searchRow.tools
            anchors.right: clearHistoryButton.visible ? clearHistoryButton.left : (selectButton.visible ? selectButton.left : addButton.left)
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            size: 40
            kind: "surface"
            icon: "sort"
            text: shortLabels[tab.sortField] || "Queue"
            onClicked: sortMenu.toggle()

            MenuPopup {
                id: sortMenu

                alignEnd: true
                menuWidth: 220
                entries: {
                    const fields = tab.sortFields
                    const labels = tab.sortLabels
                    const out = [{
                                     "heading": "Order by"
                                 }]
                    for (let i = 0; i < fields.length; i++)
                        out.push({
                                     "text": labels[i],
                                     "checked": tab.sortField === fields[i]
                                 })
                    out.push({
                                 "separator": true
                             })
                    out.push({
                                 "icon": tab.sortDesc ? "arrow_upward" : "arrow_downward",
                                 "text": tab.sortField === "queue" ? (tab.sortDesc ? "Front of the queue first" : "Back of the queue first")
                                                                   : (tab.sortDesc ? "Oldest first" : "Newest first")
                             })
                    return out
                }
                onTriggered: index => {
                    const fields = tab.sortFields
                    if (index >= 1 && index <= fields.length) {
                        const field = fields[index - 1]
                        if (field !== tab.sortField)
                            tab.setSort(field, tab.sortDefaultDesc[field])
                    } else if (index === fields.length + 2) {
                        tab.setSort(tab.sortField, !tab.sortDesc)
                    }
                }
            }
        }

        DankActionButton {
            id: selectButton

            anchors.right: addButton.left
            anchors.rightMargin: addButton.visible ? 8 : 0
            anchors.verticalCenter: parent.verticalCenter
            visible: searchRow.tools
            buttonSize: 40
            iconSize: 18
            iconName: "checklist"
            iconColor: Theme.surfaceText
            backgroundColor: Theme.surfaceContainerHigh
            tooltipText: "Select downloads"
            onClicked: tab.selecting = true
        }

        PillButton {
            id: clearHistoryButton

            //: Under Done, the record of what aria2 forgot can be cleared.
            anchors.right: selectButton.visible ? selectButton.left : addButton.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            visible: searchRow.tools && tab.filter === "complete" && tab.pastEntries.length > 0
            size: 40
            kind: "dangerText"
            icon: "delete_sweep"
            text: "Clear history"
            onClicked: tab.confirmingClearHistory = true
        }

        //: The wide window's rail has its own Add download; there this one
        //: only appears as Close while the panel is open.
        PillButton {
            id: addButton

            visible: searchRow.tools && (!tab.pickMode || tab.adding)
            width: visible ? implicitWidth : 0
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            size: 40
            kind: tab.adding ? "tonal" : "filled"
            icon: tab.adding ? "close" : "add"
            text: tab.adding ? "Close" : "Add"
            onClicked: tab.adding = !tab.adding
        }
    }

    // ---- add form --------------------------------------------------------
    //: The empty list's "Paste from clipboard": opens the Add panel with
    //: whatever links the clipboard holds.
    function pasteFromClipboard() {
        clipPeek.running = true
    }

    Process {
        id: clipPeek

        command: ["sh", "-c", "{ command -v wl-paste >/dev/null && wl-paste -n -t text 2>/dev/null || dms cl paste 2>/dev/null; } | head -c 65536"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                const links = text.split(/\s+/).filter(t => /^(https?|ftp|sftp|magnet):\S+$/i.test(t))
                if (!links.length) {
                    ToastService.showError("Nothing to paste", "The clipboard holds no http, ftp, sftp or magnet link.")
                    return
                }
                tab.adding = true
                addPanel.prefill(links.join("\n"))
            }
        }
    }

    //: The panel scrolls inside the room the tab has: an Advanced form with
    //: its groups open is taller than the popout, and its buttons must stay
    //: reachable.
    DankFlickable {
        id: addScroll

        anchors.top: searchRow.bottom
        anchors.topMargin: tab.adding ? Theme.spacingS : 0
        width: parent.width
        visible: tab.adding
        height: visible ? Math.min(addPanel.implicitHeight + 32, tab.height - searchRow.y - searchRow.height - 12) : 0
        clip: true
        contentHeight: addPanel.implicitHeight + 32
        contentWidth: width

        //: The panel is a card of its own over the list (boards 5, 16).
        Rectangle {
            width: addScroll.width - tab.scrollbarGutter
            height: addPanel.implicitHeight + 32
            radius: 18
            color: Theme.surfaceContainer

            AddPanel {
                id: addPanel

                x: 16
                y: 16
                width: parent.width - 32
                service: tab.service
                onSubmitted: tab.adding = false
                onCancelled: tab.adding = false
            }
        }
    }

    // ---- selection bar ---------------------------------------------------
    //: A contextual bar in the toolbar's place: leave, count, act, select all.
    Rectangle {
        id: selectionBar

        anchors.fill: searchRow
        visible: tab.selecting
        radius: Theme.cornerRadius
        color: Theme.primaryContainer

        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS

            DankActionButton {
                anchors.verticalCenter: parent.verticalCenter
                buttonSize: 32
                iconSize: Theme.iconSizeSmall
                iconName: "close"
                iconColor: Theme.onPrimaryContainer
                tooltipText: "Leave selection (Esc)"
                onClicked: tab.selecting = false
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: tab.selectedCount > 0 ? tab.selectedCount + " selected" : "Pick downloads · Shift-click for a range"
                font.pixelSize: Theme.fontSizeSmall + 1
                font.weight: Font.Bold
                color: Theme.onPrimaryContainer
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS

            Repeater {
                model: [["pause", "Pause the selected downloads", "pause"], ["play_arrow", "Resume the selected downloads", "resume"]]

                DankActionButton {
                    required property var modelData

                    anchors.verticalCenter: parent.verticalCenter
                    buttonSize: 32
                    iconSize: Theme.iconSizeSmall
                    iconName: modelData[0]
                    iconColor: Theme.onPrimaryContainer
                    tooltipText: modelData[1]
                    enabled: tab.selectedLive.length > 0
                    opacity: enabled ? 1 : 0.4
                    onClicked: tab.runBulk(modelData[2])
                }
            }

            DankActionButton {
                anchors.verticalCenter: parent.verticalCenter
                buttonSize: 32
                iconSize: Theme.iconSizeSmall
                iconName: "delete"
                iconColor: Theme.error
                tooltipText: tab.selectedPast.length && !tab.selectedLive.length ? "Forget the selected (files stay)" : "Remove the selected downloads"
                enabled: tab.selectedCount > 0
                opacity: enabled ? 1 : 0.4
                onClicked: tab.askBulkRemove()
            }

            DankButton {
                readonly property bool all: tab.selectedCount === tab.gids.length && tab.gids.length > 0

                anchors.verticalCenter: parent.verticalCenter
                text: all ? "Select none" : "Select all " + tab.gids.length
                buttonHeight: 32
                backgroundColor: "transparent"
                textColor: Theme.onPrimaryContainer
                onClicked: all ? tab.clearSelection() : tab.selectAllVisible()
            }
        }
    }

    //: The same question the single row asks, asked once for the batch, in
    //: one sentence that names what is finished and how big it is. Keeping
    //: the files is the safe choice, so it is the primary button.
    Rectangle {
        id: bulkBar

        readonly property var finishedRows: tab.selectedFinished.map(g => tab.byGid[g]).filter(d => !!d)
        readonly property real finishedBytes: finishedRows.reduce((sum, d) => sum + (d.total || 0), 0)
        readonly property string finishedNames: {
            const names = finishedRows.slice(0, 2).map(d => d.name || d.gid)
            const rest = finishedRows.length - names.length
            return names.join(", ") + (rest > 0 ? " and " + rest + " more" : "")
        }

        anchors.top: addScroll.bottom
        anchors.topMargin: visible ? Theme.spacingS : 0
        width: parent.width - tab.scrollbarGutter
        visible: tab.selecting && tab.confirmingBulkRemove
        height: visible ? bulkColumn.implicitHeight + Theme.spacingM * 2 : 0
        radius: 14
        color: Theme.withAlpha(Theme.error, 0.10)
        border.width: 1
        border.color: Theme.withAlpha(Theme.error, 0.35)

        Column {
            id: bulkColumn

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingS

            StyledText {
                text: "Remove " + tab.selectedCount + (tab.selectedCount === 1 ? " download?" : " downloads?")
                font.pixelSize: Theme.fontSizeMedium + 1
                font.weight: Font.Bold
                color: Theme.surfaceText
            }

            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.StyledText
                text: {
                    const rest = tab.selectedUnfinished.length
                    const done = bulkBar.finishedRows.length
                    const parts = []
                    if (rest > 0)
                        parts.push(rest + " unfinished will be cancelled and " + (rest === 1 ? "its part file" : "their part files") + " deleted.")
                    if (done > 0)
                        parts.push("<b><font color=\"" + Theme.surfaceText + "\">" + (done === 1 ? "1 is finished" : done + " are finished") + "</font></b> — "
                                   + bulkBar.finishedNames.replace(/&/g, "&amp;").replace(/</g, "&lt;") + " (" + Fmt.bytes(bulkBar.finishedBytes) + ").")
                    return parts.join(" ")
                }
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            Row {
                spacing: Theme.spacingXS

                PillButton {
                    text: bulkBar.finishedRows.length === 1 ? "Remove, keep the file" : "Remove, keep the files"
                    size: 32
                    kind: "filled"
                    onClicked: tab.runBulkRemove(true)
                }

                PillButton {
                    text: bulkBar.finishedRows.length === 1 ? "Remove and delete file" : "Remove and delete files"
                    size: 32
                    kind: "dangerFilled"
                    onClicked: tab.runBulkRemove(false)
                }

                PillButton {
                    text: "Cancel"
                    size: 32
                    kind: "text"
                    onClicked: tab.confirmingBulkRemove = false
                }
            }
        }
    }

    // ---- summary line for history ---------------------------------------
    //: Clearing forgets for good, so it asks first, saying how much it forgets.
    Rectangle {
        id: clearHistoryConfirm

        anchors.top: bulkBar.bottom
        anchors.topMargin: visible ? 12 : 0
        width: parent.width - tab.scrollbarGutter
        visible: tab.confirmingClearHistory
        height: visible ? clearColumn.implicitHeight + 26 : 0
        radius: 14
        color: Theme.withAlpha(Theme.error, 0.10)
        border.width: 1
        border.color: Theme.withAlpha(Theme.error, 0.35)

        Column {
            id: clearColumn

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 13
            spacing: 6

            StyledText {
                text: "Clear all history?"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Bold
                color: Theme.surfaceText
            }

            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                text: {
                    const count = tab.service && tab.service.history ? ((tab.service.history.summary || {}).count || 0) : 0
                    return "Forgets " + count + (count === 1 ? " entry" : " entries") + ". Files on disk are not touched."
                }
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            Row {
                topPadding: 4
                spacing: 6

                PillButton {
                    text: "Clear history"
                    size: 30
                    kind: "dangerFilled"
                    onClicked: {
                        tab.confirmingClearHistory = false
                        tab.service.post("/api/history-clear", null, "History cleared", () => tab.service.loadHistory())
                    }
                }

                PillButton {
                    text: "Cancel"
                    size: 30
                    kind: "text"
                    onClicked: tab.confirmingClearHistory = false
                }
            }
        }
    }

    // ---- list ------------------------------------------------------------
    DankListView {
        id: list

        anchors.top: clearHistoryConfirm.bottom
        anchors.topMargin: 12
        anchors.bottom: parent.bottom
        width: parent.width
        clip: true
        spacing: 6
        model: tab.gids

        //: A live download, or ("h:" + key) a finished one aria2 forgot.
        delegate: Item {
            id: rowItem

            required property var modelData
            readonly property bool past: String(modelData).indexOf("h:") === 0

            width: list.width - tab.scrollbarGutter
            height: rowLoader.item ? rowLoader.item.height : 0

            Loader {
                id: rowLoader

                width: parent.width
                sourceComponent: rowItem.past ? pastRow : liveRow
            }

            Component {
                id: liveRow

                DownloadRow {
                    width: rowItem.width
                    service: tab.service
                    gid: rowItem.modelData
                    dl: tab.byGid[rowItem.modelData] || ({})
                    expanded: tab.expandedGid === rowItem.modelData
                    selectable: tab.selecting
                    listMode: tab.pickMode && !tab.selecting
                    selected: tab.isSelected(rowItem.modelData) || (tab.pickMode && tab.selectedGid === rowItem.modelData)
                    onToggleSelected: range => tab.toggleSelection(rowItem.modelData, range)
                    onToggleExpand: {
                        if (tab.pickMode)
                            tab.selectedGid = rowItem.modelData
                        else
                            tab.expandedGid = (tab.expandedGid === rowItem.modelData ? "" : rowItem.modelData)
                    }
                }
            }

            Component {
                id: pastRow

                HistoryRow {
                    width: rowItem.width
                    service: tab.service
                    entry: tab.pastById[rowItem.modelData] || ({})
                    selectable: tab.selecting
                    selected: tab.isSelected(rowItem.modelData)
                    listMode: tab.pickMode && !tab.selecting
                    current: tab.pickMode && tab.selectedGid === rowItem.modelData
                    onToggleSelected: range => tab.toggleSelection(rowItem.modelData, range)
                    onPicked: tab.selectedGid = rowItem.modelData
                }
            }
        }
    }

    // ---- empty states ----------------------------------------------------
    //: Every empty list says why it is empty and what to do next. Not while
    //: the Add panel is open: "add a download" under a download being added
    //: contradicts it. Offline is the popout's to explain.
    Column {
        id: emptyState

        readonly property string kind: {
            if (tab.search)
                return "search"
            // Nothing at all, not just nothing under this filter.
            if (tab.filter === "all" && tab.service && (tab.service.counts.total || 0) + tab.pastEntries.length === 0)
                return "first"
            return tab.filter
        }

        readonly property var copy: ({
                "all": ["download", "No downloads yet", "Add a link here, or start a download in the browser and it lands here."],
                "active": ["downloading", "Nothing is downloading right now", "Paused and queued downloads are under their own filters."],
                "waiting": ["schedule", "The queue is empty", "Downloads wait here when more are added than run at once."],
                "paused": ["pause_circle", "Nothing is paused", ""],
                "complete": ["task_alt", "Nothing finished yet", "Finished downloads stay here, even after aria2 forgets them."],
                "error": ["task_alt", "Nothing has failed", "Downloads that stop with an error land here, with the reason and a Retry button."],
                "search": ["search_off", "Nothing matches “" + tab.search + "”", tab.suggestion ? "Did you mean “" + tab.suggestion + "”?" : ""],
                "first": ["download", "No downloads yet", "Paste a link anywhere in this panel with Ctrl V, or send one from the browser extension."]
            })

        readonly property var lines: copy[kind] || copy["all"]

        anchors.centerIn: list
        width: Math.min(list.width - Theme.spacingXL * 2, 380)
        spacing: Theme.spacingS
        visible: !!tab.service && tab.service.connected
                 && list.count === 0 && !tab.adding

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 56
            height: 56
            radius: 28
            color: emptyState.kind === "all" || emptyState.kind === "first" ? Theme.withAlpha(Theme.primary, 0.14)
                   : emptyState.kind === "error" ? Theme.withAlpha(Theme.success, 0.14)
                   : Theme.surfaceContainerHigh

            DankIcon {
                anchors.centerIn: parent
                name: emptyState.lines[0]
                size: 28
                color: emptyState.kind === "all" || emptyState.kind === "first" ? Theme.primary
                       : emptyState.kind === "error" ? Theme.success
                       : Theme.surfaceVariantText
            }
        }

        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: emptyState.lines[1]
            font.pixelSize: Theme.fontSizeLarge
            font.weight: Font.Bold
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: text.length > 0
            text: emptyState.lines[2]
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingS
            topPadding: Theme.spacingXS

            PillButton {
                visible: emptyState.kind === "all" || emptyState.kind === "first"
                text: "Add download"
                icon: "add"
                size: 34
                kind: "filled"
                onClicked: tab.adding = true
            }

            PillButton {
                visible: emptyState.kind === "first"
                text: "Paste from clipboard"
                icon: "content_paste"
                size: 34
                kind: "outlined"
                onClicked: tab.pasteFromClipboard()
            }

            PillButton {
                visible: emptyState.kind === "search"
                text: "Clear search"
                size: 34
                kind: "outlined"
                onClicked: searchField.text = ""
            }

            PillButton {
                visible: ["all", "first", "search"].indexOf(emptyState.kind) === -1
                text: "Show all downloads"
                size: 34
                kind: "outlined"
                onClicked: tab.setFilter("all")
            }
        }
    }
}
