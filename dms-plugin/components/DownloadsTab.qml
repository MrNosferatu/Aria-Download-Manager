import QtQuick
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

    readonly property int scrollbarGutter: Layout.SCROLLBAR_GUTTER

    // ---- bulk selection --------------------------------------------------
    //: gid -> true. A plain object rather than a list so a row can test its own
    //: membership without scanning, and so reassigning it is one signal.
    property var selection: ({})
    property bool selecting: false
    property bool confirmingBulkRemove: false

    //: A selection can mix the two cases, so they are counted separately: the
    //: unfinished ones are cleaned up without asking, and only the finished
    //: ones raise the question of whether to keep what was downloaded.
    readonly property var selectedFinished: selectedGids.filter(g => (byGid[g] || {}).status === "complete")
    readonly property var selectedUnfinished: selectedGids.filter(g => (byGid[g] || {}).status !== "complete")

    readonly property var selectedGids: Object.keys(selection).filter(g => selection[g])
    readonly property int selectedCount: selectedGids.length

    function isSelected(gid) {
        return selection[gid] === true
    }

    function toggleSelection(gid) {
        const next = Object.assign({}, selection)
        if (next[gid])
            delete next[gid]
        else
            next[gid] = true
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
    onFilterChanged: clearSelection()
    onSelectingChanged: {
        if (!selecting)
            clearSelection()
    }

    function runBulk(action) {
        if (!selectedCount)
            return
        service.bulk(action, selectedGids, false, () => tab.clearSelection())
    }

    //: `keepFinishedFiles` only governs the finished downloads; a part file is
    //: never worth keeping, so those always go with their rows.
    function runBulkRemove(keepFinishedFiles) {
        const unfinished = selectedUnfinished
        const finished = selectedFinished
        if (unfinished.length)
            service.bulk("remove", unfinished, true)
        if (finished.length)
            service.bulk("remove", finished, !keepFinishedFiles)
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

    readonly property bool historyMode: filter === "history"

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
        if (!service || historyMode)
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
        list.sort((a, b) => {
            const diff = rankOf(a) - rankOf(b)
            if (diff)
                return diff
            return (a.queuePosition || 0) - (b.queuePosition || 0)
        })

        const next = list.map(d => d.gid)
        if (next.join(",") !== gids.join(","))
            gids = next
    }

    function setFilter(name) {
        filter = name
        if (!service)
            return
        if (name === "history")
            service.loadHistory()
        else
            recompute()
    }

    onSearchChanged: recompute()

    Component.onCompleted: recompute()

    Connections {
        target: tab.service
        function onSnapshotChanged() {
            tab.recompute()
        }
    }

    // ---- filters ---------------------------------------------------------
    DankFilterChips {
        id: chips

        width: parent.width
        chipHeight: 30
        showCounts: true
        currentIndex: 0
        model: {
            const c = tab.service ? tab.service.counts : ({})
            return [
                {
                    "label": "All",
                    "value": "all",
                    "count": c.total || 0
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
                    "label": "Complete",
                    "value": "complete",
                    "count": c.complete || 0
                },
                {
                    "label": "Error",
                    "value": "error",
                    "count": c.error || 0
                },
                {
                    "label": "History",
                    "value": "history"
                }
            ]
        }

        onSelectionChanged: index => {
            tab.setFilter(["all", "active", "waiting", "paused", "complete", "error", "history"][index])
        }
    }

    Item {
        id: searchRow

        anchors.top: chips.bottom
        anchors.topMargin: Theme.spacingS
        width: parent.width
        height: 44

        DankTextField {
            id: searchField

            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, parent.width - addButton.width - Theme.spacingS
                                - (selectButton.visible ? selectButton.width + Theme.spacingS : 0)
                                - (clearHistoryButton.visible ? clearHistoryButton.width + Theme.spacingS : 0))
            height: 40
            leftIconName: "search"
            placeholderText: tab.historyMode ? "History is filtered on the server" : "Filter by name…"
            showClearButton: true
            onTextChanged: tab.search = text
        }

        DankButton {
            id: clearHistoryButton

            anchors.right: addButton.left
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            visible: tab.historyMode
            text: "Clear history"
            iconName: "delete_sweep"
            buttonHeight: 40
            backgroundColor: Theme.errorHover
            textColor: Theme.error
            onClicked: tab.service.post("/api/history-clear", null, "History cleared", () => tab.service.loadHistory())
        }

        DankButton {
            id: selectButton

            anchors.right: addButton.left
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            visible: !tab.historyMode
            text: tab.selecting ? "Done" : "Select"
            iconName: tab.selecting ? "check" : "checklist"
            buttonHeight: 40
            backgroundColor: tab.selecting ? Theme.primary : Theme.surfaceContainerHigh
            textColor: tab.selecting ? Theme.onPrimary : Theme.surfaceText
            onClicked: tab.selecting = !tab.selecting
        }

        DankButton {
            id: addButton

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: tab.adding ? "Close" : "Add"
            iconName: tab.adding ? "close" : "add"
            buttonHeight: 40
            backgroundColor: tab.adding ? Theme.surfaceContainerHigh : Theme.primary
            textColor: tab.adding ? Theme.surfaceText : Theme.onPrimary
            onClicked: tab.adding = !tab.adding
        }
    }

    // ---- add form --------------------------------------------------------
    AddPanel {
        id: addPanel

        anchors.top: searchRow.bottom
        anchors.topMargin: tab.adding ? Theme.spacingS : 0
        width: parent.width
        visible: tab.adding
        height: visible ? implicitHeight : 0
        service: tab.service
        onSubmitted: tab.adding = false
    }

    // ---- bulk action bar -------------------------------------------------
    Rectangle {
        id: bulkBar

        anchors.top: addPanel.bottom
        anchors.topMargin: visible ? Theme.spacingS : 0
        width: parent.width - tab.scrollbarGutter
        visible: tab.selecting && !tab.historyMode
        height: visible ? (tab.confirmingBulkRemove ? 76 : 40) : 0
        radius: Theme.cornerRadius
        color: tab.confirmingBulkRemove ? Theme.withAlpha(Theme.error, 0.10) : Theme.surfaceContainerHigh
        border.width: 1
        border.color: tab.confirmingBulkRemove ? Theme.withAlpha(Theme.error, 0.35)
                                               : Theme.withAlpha(Theme.outline, 0.12)

        Item {
            id: bulkRow

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 40

            StyledText {
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                text: tab.selectedCount > 0 ? tab.selectedCount + " selected" : "Select downloads"
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            Row {
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                DankButton {
                    text: tab.selectedCount === tab.gids.length && tab.gids.length > 0 ? "None" : "All"
                    buttonHeight: 28
                    backgroundColor: Theme.surfaceContainer
                    textColor: Theme.surfaceText
                    onClicked: {
                        if (tab.selectedCount === tab.gids.length && tab.gids.length > 0)
                            tab.clearSelection()
                        else
                            tab.selectAllVisible()
                    }
                }

                DankActionButton {
                    buttonSize: 28
                    iconSize: Theme.iconSizeSmall
                    iconName: "pause"
                    tooltipText: "Pause the selected downloads"
                    enabled: tab.selectedCount > 0
                    opacity: enabled ? 1 : 0.4
                    onClicked: tab.runBulk("pause")
                }

                DankActionButton {
                    buttonSize: 28
                    iconSize: Theme.iconSizeSmall
                    iconName: "play_arrow"
                    tooltipText: "Resume the selected downloads"
                    enabled: tab.selectedCount > 0
                    opacity: enabled ? 1 : 0.4
                    onClicked: tab.runBulk("resume")
                }

                DankActionButton {
                    buttonSize: 28
                    iconSize: Theme.iconSizeSmall
                    iconName: "delete"
                    iconColor: Theme.error
                    tooltipText: "Remove the selected downloads"
                    enabled: tab.selectedCount > 0
                    opacity: enabled ? 1 : 0.4
                    onClicked: tab.askBulkRemove()
                }
            }
        }

        // The same question the single row asks, asked once for the batch —
        // and only about the finished downloads in it.
        Item {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: bulkRow.bottom
            height: 36
            visible: tab.confirmingBulkRemove

            StyledText {
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacingS
                anchors.right: bulkConfirmButtons.left
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                text: {
                    const done = tab.selectedFinished.length
                    const rest = tab.selectedUnfinished.length
                    let line = done + " finished — keep the files?"
                    if (rest > 0)
                        line += "  (" + rest + " unfinished will be cleaned up)"
                    return line
                }
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                elide: Text.ElideRight
            }

            Row {
                id: bulkConfirmButtons

                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                DankButton {
                    text: "Cancel"
                    buttonHeight: 28
                    backgroundColor: Theme.surfaceContainer
                    textColor: Theme.surfaceText
                    onClicked: tab.confirmingBulkRemove = false
                }

                DankButton {
                    text: "Keep files"
                    buttonHeight: 28
                    backgroundColor: Theme.surfaceContainer
                    textColor: Theme.surfaceText
                    onClicked: tab.runBulkRemove(true)
                }

                DankButton {
                    text: "Delete files"
                    buttonHeight: 28
                    backgroundColor: Theme.error
                    textColor: Theme.onPrimary
                    onClicked: tab.runBulkRemove(false)
                }
            }
        }
    }

    // ---- summary line for history ---------------------------------------
    StyledText {
        id: historySummary

        anchors.top: bulkBar.bottom
        anchors.topMargin: Theme.spacingS
        width: parent.width
        visible: tab.historyMode
        height: visible ? implicitHeight : 0
        text: {
            if (!tab.service || !tab.service.history)
                return ""
            const s = tab.service.history.summary || ({})
            return (s.count || 0) + " recorded · " + (s.completed || 0) + " completed · " + Fmt.bytes(s.bytes || 0)
        }
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        elide: Text.ElideRight
    }

    // ---- list ------------------------------------------------------------
    DankListView {
        id: list

        anchors.top: historySummary.bottom
        anchors.topMargin: Theme.spacingS
        anchors.bottom: parent.bottom
        width: parent.width
        clip: true
        spacing: Theme.spacingXS
        visible: !tab.historyMode
        model: tab.gids

        delegate: DownloadRow {
            required property var modelData

            width: list.width - tab.scrollbarGutter
            service: tab.service
            gid: modelData
            dl: tab.byGid[modelData] || ({})
            expanded: tab.expandedGid === modelData
            selectable: tab.selecting
            selected: tab.isSelected(modelData)
            onToggleSelected: tab.toggleSelection(modelData)
            onToggleExpand: tab.expandedGid = (tab.expandedGid === modelData ? "" : modelData)
        }
    }

    DankListView {
        id: historyList

        anchors.top: historySummary.bottom
        anchors.topMargin: Theme.spacingS
        anchors.bottom: parent.bottom
        width: parent.width
        clip: true
        spacing: Theme.spacingXS
        visible: tab.historyMode
        model: tab.service && tab.service.history ? (tab.service.history.entries || []) : []

        delegate: HistoryRow {
            required property var modelData

            width: historyList.width - tab.scrollbarGutter
            service: tab.service
            entry: modelData
        }
    }

    StyledText {
        anchors.centerIn: list
        width: list.width - Theme.spacingXL * 2
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        visible: tab.historyMode ? historyList.count === 0 : list.count === 0
        text: {
            if (!tab.service || !tab.service.connected)
                return "Can't reach aria2c-manager at " + (tab.service ? tab.service.baseUrl : "") + ".\nStart it with run.sh or the systemd unit."
            if (tab.historyMode)
                return "Nothing recorded yet."
            return tab.filter === "all" && !tab.search ? "No downloads. Hit Add, or send one from the browser extension." : "Nothing matches this filter."
        }
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
    }
}
