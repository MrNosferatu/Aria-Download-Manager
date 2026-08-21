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

    // ---- summary line for history ---------------------------------------
    StyledText {
        id: historySummary

        anchors.top: addPanel.bottom
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
